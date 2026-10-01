"""Simulated ForceDecks countermovement-jump export for the CMJ Trend Report demo.

Built from scratch: no real athlete data is used or derived. Values come from simple
physical relationships (jump height from takeoff velocity, force from bodyweight and
countermovement depth) plus athlete traits, a season-long training/fatigue trend,
return-to-play recovery curves, and test-retest noise in line with published CMJ typical
error (~3-5% for jump height).

Output matches the header layout of a ForceDecks CMJ export, including bracketed units
and trailing spaces.
"""
import csv
import math
import random
from datetime import date, timedelta
from pathlib import Path

SEED = 2026
G = 9.81
OUT = Path(__file__).resolve().parent.parent / "sample_data" / "forcedecks_cmj_demo.csv"

HEADERS = ["Name", "ExternalId", "Test Type", "Date", "Time", "BW [KG]", "Reps", "Tags", "Additional Load [lb]",
           "Jump Height (Imp-Mom) [cm]", "Contraction Time [ms] ", "Peak Power / BM [W/kg] ",
           "Bodyweight in Pounds [lbs] ", "CMJ Stiffness [N/m] ", "Vertical Velocity at Takeoff [m/s] ",
           "Eccentric Braking RFD [N/s] ", "Positive Impulse [N s] ", "Concentric Mean Force [N] ",
           "Concentric Impulse % (Asym) (%)", "Velocity at Peak Power [m/s] ", "Force at Zero Velocity [N] ",
           "Countermovement Depth [cm] ", "Eccentric Braking Impulse % (Asym) (%)"]

SEASON_START = date(2026, 2, 16)   # Monday of the first testing week
SEASON_END = date(2026, 9, 28)


def asym_text(value: float) -> str:
    """ForceDecks style: magnitude then the side that is higher, e.g. '6.4 L'."""
    side = "L" if value < 0 else "R"
    return f"{abs(value):.1f} {side}"


def make_athletes(rng: random.Random, n_healthy: int = 16, n_rtp: int = 4):
    athletes = []
    for i in range(n_healthy + n_rtp):
        rtp = i >= n_healthy
        bw = rng.uniform(80, 106)
        athletes.append({
            "name": f"Demo Athlete {i + 1:02d}",
            "ext": f"DEMO{i + 1:03d}",
            "bw": bw,
            "jh_in": rng.uniform(14.5, 20.5) - (bw - 92) * 0.04,   # heavier athletes jump slightly less
            "ct_ms": rng.uniform(660, 900),                          # strategy trait: fast vs slow countermovement
            "depth_cm": rng.uniform(27, 38),
            "asym_bias": rng.gauss(0, 3.0),                         # habitual side bias
            "rtp": rtp,
            # return-to-play athletes start testing part-way through the season
            "start": SEASON_START + timedelta(weeks=rng.randint(6, 14)) if rtp else SEASON_START,
            "injured_side": rng.choice([-1, 1]),
            "attendance": rng.uniform(0.8, 0.95),
        })
    return athletes


def season_effect(d: date) -> float:
    """Multiplier on output: pre-season build, mid-summer fatigue dip, late-season recovery."""
    week = (d - SEASON_START).days / 7
    build = 0.03 * (1 - math.exp(-week / 4))
    fatigue = -0.035 * math.exp(-((week - 22) / 5) ** 2)
    return 1 + build + fatigue


def rtp_effect(weeks_in: float) -> float:
    """Return-to-play recovery: starts ~22% down and closes toward baseline."""
    return 1 - 0.22 * math.exp(-weeks_in / 6)


def simulate(rng: random.Random):
    rows = []
    for a in make_athletes(rng):
        d = a["start"]
        step = 14 if a["rtp"] else 7
        while d <= SEASON_END:
            if rng.random() < a["attendance"]:
                test_day = d + timedelta(days=rng.choice([0, 0, 1, 2]))
                weeks_in = (test_day - a["start"]).days / 7
                scale = season_effect(test_day) * (rtp_effect(weeks_in) if a["rtp"] else 1)

                bw = a["bw"] + rng.gauss(0, 0.5) - (0.6 if a["rtp"] and weeks_in < 6 else 0)
                jh_in = a["jh_in"] * scale * (1 + rng.gauss(0, 0.035))
                jh_m = jh_in * 0.0254
                v_to = math.sqrt(2 * G * jh_m)                                   # impulse-momentum
                depth_m = a["depth_cm"] / 100 * (1 + rng.gauss(0, 0.05))
                ct = a["ct_ms"] * (1 + rng.gauss(0, 0.04)) * (1 + (0.12 * math.exp(-weeks_in / 6) if a["rtp"] else 0))
                conc_mean_f = bw * G + bw * v_to ** 2 / (2 * depth_m)             # work-energy over the push-off
                f_zero_v = conc_mean_f * rng.uniform(1.10, 1.18)
                stiffness = f_zero_v / depth_m
                ecc_rfd = (f_zero_v - bw * G) / (ct / 1000 * 0.45) * rng.uniform(0.9, 1.1)
                pos_impulse = bw * v_to * rng.uniform(1.12, 1.18)
                pp_bm = v_to * rng.uniform(20.3, 21.6)
                v_pp = v_to * rng.uniform(0.93, 0.96)

                rtp_asym = a["injured_side"] * 18 * math.exp(-weeks_in / 7) if a["rtp"] else 0
                conc_asym = a["asym_bias"] + rtp_asym + rng.gauss(0, 2.5)
                ecc_asym = a["asym_bias"] * 1.2 + rtp_asym * 1.3 + rng.gauss(0, 3.5)

                hour = rng.choice([7, 8, 8, 9, 9, 10])
                rows.append([
                    a["name"], a["ext"], "CMJ", f"{test_day.month}/{test_day.day}/{test_day.year}",
                    f"{hour}:{rng.randint(0, 59):02d} AM", f"{bw:.1f}", 3, "", 0,
                    f"{jh_in * 2.54:.1f}", f"{ct:.0f}", f"{pp_bm:.2f}", f"{bw * 2.20462:.1f}", f"{stiffness:.0f}",
                    f"{v_to:.3f}", f"{ecc_rfd:.0f}", f"{pos_impulse:.1f}", f"{conc_mean_f:.0f}",
                    asym_text(conc_asym), f"{v_pp:.3f}", f"{f_zero_v:.0f}", f"{-depth_m * 100:.1f}",
                    asym_text(ecc_asym),
                ])
            d += timedelta(days=step)
    rows.sort(key=lambda r: (date(*map(int, (r[3].split("/")[2], r[3].split("/")[0], r[3].split("/")[1]))), r[0]))
    return rows


if __name__ == "__main__":
    rows = simulate(random.Random(SEED))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(HEADERS)
        w.writerows(rows)
    print(f"{len(rows)} tests for {len({r[0] for r in rows})} simulated athletes -> {OUT}")
