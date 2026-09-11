"""
tools/simulate_throughput.py — Module 5 Python support runner for DRishti-AI.

Runs the discrete-event telemedicine queuing simulation and district capacity
planning model (100,000 patients/year) independently of MATLAB/Simulink.
Provides identical math, parameters, and reporting as simulink/simulate_district_throughput.m.

Usage:
    python tools/simulate_throughput.py
    python tools/simulate_throughput.py --days 10 --ophth 4
"""

import argparse
import random
import math
import numpy as np


def get_default_params():
    return {
        "district_population": 1.8e6,
        "annual_screening_target": 100000,
        "operating_days_per_year": 250,
        "operating_hours_per_day": 8.0,
        "target_patients_per_day": 400.0,
        "num_phcs": 40,
        "num_vans": 4,
        "total_cameras": 44,
        "technicians_per_camera": 1,
        "mean_exam_minutes": 7.5,
        "std_exam_minutes": 1.5,
        "images_per_patient": 4,
        "raw_image_mb": 3.5,
        "total_payload_mb": 14.0,
        "initial_reject_rate": 0.12,
        "immediate_recapture_prob": 0.85,
        "recapture_minutes": 2.5,
        "permanent_reject_rate": 0.02,
        "uplink_bandwidth_kbps": 1024.0,
        "min_bandwidth_kbps": 256.0,
        "network_failure_prob": 0.05,
        "mean_dropout_minutes": 20.0,
        "ai_inference_sec": 0.120,
        "num_compute_nodes": 2,
        "review_sec_grade0": 15.0,
        "review_sec_grade1": 25.0,
        "review_sec_grade2": 30.0,
        "review_sec_grade3": 60.0,
        "review_sec_grade4": 90.0,
        "prob_grade0": 0.72,
        "prob_grade1": 0.12,
        "prob_grade2": 0.09,
        "prob_grade3": 0.04,
        "prob_grade4": 0.03,
        "num_ophthalmologists": 3,
        "ophthalmologist_shift_hrs": 6.5,
        "target_sameday_tat_min": 120.0,
    }


def simulate_district(params, num_days=5):
    total_centers = params["total_cameras"]
    patients_per_center_per_day = math.ceil(params["target_patients_per_day"] / total_centers)
    sim_minutes_per_day = params["operating_hours_per_day"] * 60.0

    all_patients = []

    for d in range(num_days):
        day_offset = d * sim_minutes_per_day
        day_patients = []

        # Parallel Stage 1 & 3 at each center
        for c in range(total_centers):
            camera_free_time = day_offset
            upload_free_time = day_offset

            n_pts = max(1, int(round(random.gauss(patients_per_center_per_day, 1.5))))
            raw_arrivals = sorted([random.uniform(0, 6.5 * 60.0) + day_offset for _ in range(n_pts)])

            for arr_time in raw_arrivals:
                # Stage 1: Acquisition
                acq_start = max(arr_time, camera_free_time)
                exam_dur = max(4.0, random.gauss(params["mean_exam_minutes"], params["std_exam_minutes"]))

                # Stage 2: Quality Gate
                recaptured = False
                perm_reject = False
                if random.random() < params["initial_reject_rate"]:
                    if random.random() < params["immediate_recapture_prob"]:
                        exam_dur += params["recapture_minutes"]
                        recaptured = True
                    else:
                        perm_reject = True

                acq_end = acq_start + exam_dur
                camera_free_time = acq_end

                # Grade assignment
                r = random.random()
                if r < params["prob_grade0"]:
                    grade = 0
                elif r < (params["prob_grade0"] + params["prob_grade1"]):
                    grade = 1
                elif r < (params["prob_grade0"] + params["prob_grade1"] + params["prob_grade2"]):
                    grade = 2
                elif r < (params["prob_grade0"] + params["prob_grade1"] + params["prob_grade2"] + params["prob_grade3"]):
                    grade = 3
                else:
                    grade = 4

                if perm_reject:
                    day_patients.append({
                        "arr_time": arr_time,
                        "acq_start": acq_start,
                        "acq_end": acq_end,
                        "up_end": acq_end,
                        "tat": acq_end - arr_time,
                        "grade": grade,
                        "perm_reject": True,
                        "recaptured": False,
                        "acq_dur": exam_dur,
                        "up_dur": 0.0,
                        "ai_dur": 0.0,
                        "rev_dur": 0.0
                    })
                    continue

                # Stage 3: Network Upload
                payload_bits = params["total_payload_mb"] * 8 * 1024 * 1024
                eff_bw = max(params["min_bandwidth_kbps"] * 1000, random.gauss(params["uplink_bandwidth_kbps"] * 1000, 200000))
                transfer_sec = payload_bits / eff_bw
                if random.random() < params["network_failure_prob"]:
                    transfer_sec += params["mean_dropout_minutes"] * 60.0
                transfer_min = transfer_sec / 60.0

                up_start = max(acq_end, upload_free_time)
                up_end = up_start + transfer_min
                upload_free_time = up_end

                day_patients.append({
                    "arr_time": arr_time,
                    "acq_start": acq_start,
                    "acq_end": acq_end,
                    "up_start": up_start,
                    "up_end": up_end,
                    "grade": grade,
                    "perm_reject": False,
                    "recaptured": recaptured,
                    "acq_dur": exam_dur,
                    "up_dur": transfer_min
                })

        # Interleaved Central Processing for day d
        valid_day_pts = [p for p in day_patients if not p["perm_reject"]]
        valid_day_pts.sort(key=lambda p: p["up_end"])

        ai_free_time = [day_offset] * params["num_compute_nodes"]
        ophth_free_time = [day_offset] * params["num_ophthalmologists"]
        ai_dur_min = (params["images_per_patient"] * params["ai_inference_sec"]) / 60.0

        for p in valid_day_pts:
            # Stage 4: AI Compute
            best_node = min(range(params["num_compute_nodes"]), key=lambda i: ai_free_time[i])
            ai_start = max(p["up_end"], ai_free_time[best_node])
            ai_end = ai_start + ai_dur_min
            ai_free_time[best_node] = ai_end

            # Stage 5: Ophthalmologist Review
            rev_sec_map = {
                0: params["review_sec_grade0"],
                1: params["review_sec_grade1"],
                2: params["review_sec_grade2"],
                3: params["review_sec_grade3"],
                4: params["review_sec_grade4"],
            }
            nominal_rev = rev_sec_map[p["grade"]]
            actual_rev_sec = max(5.0, random.gauss(nominal_rev, nominal_rev * 0.15))
            rev_min = actual_rev_sec / 60.0

            best_ophth = min(range(params["num_ophthalmologists"]), key=lambda i: ophth_free_time[i])
            rev_start = max(ai_end, ophth_free_time[best_ophth])
            rev_end = rev_start + rev_min
            ophth_free_time[best_ophth] = rev_end

            p["ai_start"] = ai_start
            p["ai_end"] = ai_end
            p["ai_dur"] = ai_dur_min
            p["rev_start"] = rev_start
            p["rev_end"] = rev_end
            p["rev_dur"] = rev_min
            p["tat"] = rev_end - p["arr_time"]

        all_patients.extend(day_patients)

    # Metrics
    total_pts = len(all_patients)
    valid_pts = [p for p in all_patients if not p["perm_reject"]]
    perm_rejects = [p for p in all_patients if p["perm_reject"]]
    tats = [p["tat"] for p in valid_pts]

    total_sim_min = num_days * sim_minutes_per_day
    cam_busy = sum(p["acq_dur"] for p in all_patients)
    cam_util = cam_busy / (total_centers * total_sim_min)

    up_busy = sum(p["up_dur"] for p in valid_pts)
    up_util = up_busy / (total_centers * total_sim_min)

    ai_busy = sum(p["ai_dur"] for p in valid_pts)
    ai_util = ai_busy / (params["num_compute_nodes"] * total_sim_min)

    rev_busy = sum(p["rev_dur"] for p in valid_pts)
    clin_shift_min = num_days * params["num_ophthalmologists"] * (params["ophthalmologist_shift_hrs"] * 60.0)
    rev_util = rev_busy / clin_shift_min

    sla_1hr = 100.0 * sum(1 for t in tats if t <= 60.0) / len(tats)
    sla_2hr = 100.0 * sum(1 for t in tats if t <= params["target_sameday_tat_min"]) / len(tats)
    sla_24hr = 100.0 * sum(1 for t in tats if t <= 1440.0) / len(tats)

    stages = [
        ("Camera / Technician Acquisition", cam_util),
        ("Rural Network Uplink", up_util),
        ("Central AI GPU Inference", ai_util),
        ("Tele-Ophthalmologist Review", rev_util)
    ]
    bottleneck_stage, bottleneck_util = max(stages, key=lambda s: s[1])

    annual_proj = (total_pts / num_days) * params["operating_days_per_year"]

    return {
        "num_days": num_days,
        "total_patients": total_pts,
        "screened_patients": len(valid_pts),
        "perm_reject_count": len(perm_rejects),
        "perm_reject_pct": 100.0 * len(perm_rejects) / total_pts,
        "recaptured_count": sum(1 for p in valid_pts if p["recaptured"]),
        "annual_throughput_proj": annual_proj,
        "mean_tat": float(np.mean(tats)),
        "median_tat": float(np.median(tats)),
        "p90_tat": float(np.percentile(tats, 90)),
        "p95_tat": float(np.percentile(tats, 95)),
        "p99_tat": float(np.percentile(tats, 99)),
        "max_tat": float(np.max(tats)),
        "cam_util": cam_util,
        "network_util": up_util,
        "ai_util": ai_util,
        "ophth_util": rev_util,
        "sla_1hr": sla_1hr,
        "sla_2hr": sla_2hr,
        "sla_24hr": sla_24hr,
        "bottleneck_stage": bottleneck_stage,
        "bottleneck_util": bottleneck_util
    }


def main():
    parser = argparse.ArgumentParser(description="DRishti-AI Screening Throughput Simulation")
    parser.add_argument("--days", type=int, default=5, help="Simulation duration in business days")
    parser.add_argument("--ophth", type=int, default=3, help="Number of tele-ophthalmologists")
    parser.add_argument("--bw", type=float, default=1024.0, help="Uplink bandwidth in Kbps")
    args = parser.parse_args()

    params = get_default_params()
    params["num_ophthalmologists"] = args.ophth
    params["uplink_bandwidth_kbps"] = args.bw

    print("\n" + "=" * 68)
    print("  DRishti-AI: District-Scale Telemedicine Screening Simulation")
    print(f"  Target: 100,000 Patients/Year | Simulated Duration: {args.days} Days")
    print("=" * 68 + "\n")

    res = simulate_district(params, num_days=args.days)

    print(f"  Total Patients Processed : {res['total_patients']} ({res['total_patients'] / args.days:.1f} / day)")
    print(f"  Annualized Projection    : {res['annual_throughput_proj']:,.0f} patients / year (Target: 100,000)")
    print(f"  Permanent Rejects        : {res['perm_reject_count']} ({res['perm_reject_pct']:.1f}%)")
    print(f"  Immediate Recaptures     : {res['recaptured_count']} on-site retakes via Mod 1 gate")
    print("-" * 68)
    print("  Turnaround Times (End-to-End Patient Waiting Time):")
    print(f"    - Mean TAT             : {res['mean_tat']:.1f} minutes")
    print(f"    - Median (p50) TAT     : {res['median_tat']:.1f} minutes")
    print(f"    - 90th Percentile (p90): {res['p90_tat']:.1f} minutes")
    print(f"    - 95th Percentile (p95): {res['p95_tat']:.1f} minutes")
    print(f"    - Max TAT              : {res['max_tat']:.1f} minutes")
    print("-" * 68)
    print("  SLA Delivery Compliance:")
    print(f"    - Within 1 Hour        : {res['sla_1hr']:.1f}%")
    print(f"    - Within 2 Hours (PHC) : {res['sla_2hr']:.1f}%  <-- Same-day clinic release")
    print(f"    - Within 24 Hours      : {res['sla_24hr']:.1f}%")
    print("-" * 68)
    print("  Resource Utilization Rates:")
    print(f"    - Cameras & Techs (44) : {res['cam_util'] * 100:.1f}%")
    print(f"    - Rural Uplink (1Mbps) : {res['network_util'] * 100:.1f}%")
    print(f"    - AI GPU Servers (2)   : {res['ai_util'] * 100:.1f}%")
    print(f"    - Ophthalmologists ({args.ophth}) : {res['ophth_util'] * 100:.1f}%  (Target: 60-80% safe band)")
    print("-" * 68)
    print(f"  CRITICAL BOTTLENECK      : {res['bottleneck_stage']} ({res['bottleneck_util'] * 100:.1f}% Load)")
    print("=" * 68 + "\n")


if __name__ == "__main__":
    main()
