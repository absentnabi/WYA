#!/usr/bin/env python3
"""Build a compact NYC transit index from official MTA GTFS static feeds.

Downloads are not performed here. Point --gtfs at a directory of the official
zip files (see the README) or let the defaults read /tmp/mta-gtfs.

The index is a derived subset: stops, route colors, and one or more typical
stop sequences per route and direction with cumulative travel seconds. Realtime
arrivals are not baked in.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
import time
import zipfile
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

EXPRESS_PREFIXES = ("SIM", "QM", "BxM", "BM", "X")

FEEDS = [
    ("NYCT Subway GTFS", "gtfs_subway.zip", "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip"),
    ("NYCT Bus Manhattan", "gtfs_m.zip", "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_m.zip"),
    ("NYCT Bus Bronx", "gtfs_bx.zip", "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_bx.zip"),
    ("NYCT Bus Brooklyn", "gtfs_b.zip", "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_b.zip"),
    ("NYCT Bus Queens", "gtfs_q.zip", "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_q.zip"),
    ("NYCT Bus Staten Island", "gtfs_si.zip", "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_si.zip"),
    ("MTA Bus Company", "gtfs_busco.zip", "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_busco.zip"),
]

SUBWAY_ORDER = [
    "1", "2", "3", "4", "5", "6", "6X", "7", "7X",
    "A", "C", "E", "B", "D", "F", "FX", "M", "G", "J", "Z", "L",
    "N", "Q", "R", "W", "GS", "FS", "H", "SI",
]
ORDER_INDEX = {route: index for index, route in enumerate(SUBWAY_ORDER)}


def intern(value: str) -> str:
    return sys.intern(value)


def is_express(short_name: str, long_name: str) -> bool:
    compact = short_name.replace(" ", "")
    for prefix in EXPRESS_PREFIXES:
        if compact.startswith(prefix) and len(compact) > len(prefix) and compact[len(prefix)].isdigit():
            return True
    return "express" in long_name.lower()


def mode_for(route_type: int, short_name: str, long_name: str) -> str | None:
    if route_type in (1, 2):
        return "subway"
    if route_type != 3:
        return None
    if is_express(short_name, long_name):
        return "expressBus"
    return "localBus"


def parse_hms(value: str) -> int | None:
    if not value:
        return None
    parts = value.strip().split(":")
    if len(parts) != 3:
        return None
    try:
        hours, minutes, seconds = (int(part) for part in parts)
    except ValueError:
        return None
    return hours * 3600 + minutes * 60 + seconds


def haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    h = math.sin(dlat / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlon / 2) ** 2
    return 2 * radius * math.asin(min(1.0, math.sqrt(h)))


def channel(value: int) -> float:
    s = value / 255.0
    if s <= 0.04045:
        return s / 12.92
    return ((s + 0.055) / 1.055) ** 2.4


def luminance(hex_color: str) -> float:
    red = int(hex_color[0:2], 16)
    green = int(hex_color[2:4], 16)
    blue = int(hex_color[4:6], 16)
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)


def contrast(hex_a: str, hex_b: str) -> float:
    left, right = luminance(hex_a), luminance(hex_b)
    lighter, darker = max(left, right), min(left, right)
    return (lighter + 0.05) / (darker + 0.05)


def readable_text(background: str, preferred: str) -> str:
    preferred = (preferred or "FFFFFF").strip().upper()
    background = background.strip().upper()
    if len(preferred) != 6:
        preferred = "FFFFFF"
    if contrast(background, preferred) >= 3.0:
        return preferred
    black = contrast(background, "000000")
    white = contrast(background, "FFFFFF")
    return "000000" if black >= white else "FFFFFF"


@dataclass
class StopRec:
    name: str
    lat: float
    lon: float
    parent: str | None
    location_type: str


@dataclass
class RouteRec:
    short_name: str
    long_name: str
    mode: str
    color: str
    text_color: str


@dataclass
class TripRec:
    route_id: str
    direction: int
    headsign: str
    weekday: bool


@dataclass
class PatternAccum:
    stops: tuple[str, ...]
    count: int = 0
    times: list[int] = field(default_factory=list)
    headsign: str = ""
    noon_score: int = 10**9
    weekday_sample: bool = False


def read_csv(zip_file: zipfile.ZipFile, name: str):
    raw = zip_file.open(name)
    text = (line.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n") for line in raw)
    return csv.DictReader(text)


def load_feed(path: Path, stops: dict[str, StopRec], routes: dict[str, RouteRec], trips: dict[str, TripRec]) -> None:
    with zipfile.ZipFile(path) as archive:
        for row in read_csv(archive, "routes.txt"):
            route_id = intern(row["route_id"].strip())
            if route_id in routes:
                continue
            short = (row.get("route_short_name") or route_id).strip() or route_id
            long_name = (row.get("route_long_name") or "").strip()
            desc = (row.get("route_desc") or "").strip()
            try:
                route_type = int(row.get("route_type") or "0")
            except ValueError:
                continue
            mode = mode_for(route_type, short, f"{long_name} {desc}")
            if mode is None:
                continue
            color = (row.get("route_color") or "").strip().upper() or ("0062CF" if mode == "subway" else "0039A6")
            if len(color) != 6:
                color = "0039A6"
            text = readable_text(color, (row.get("route_text_color") or "FFFFFF").strip().upper())
            routes[route_id] = RouteRec(short, long_name or short, mode, color, text)

        for row in read_csv(archive, "stops.txt"):
            stop_id = intern(row["stop_id"].strip())
            if stop_id in stops:
                continue
            try:
                lat = float(row["stop_lat"])
                lon = float(row["stop_lon"])
            except (KeyError, ValueError):
                continue
            if not (40.40 <= lat <= 41.05 and -74.40 <= lon <= -73.60):
                continue
            parent = (row.get("parent_station") or "").strip()
            stops[stop_id] = StopRec(
                name=(row.get("stop_name") or stop_id).strip() or stop_id,
                lat=lat,
                lon=lon,
                parent=intern(parent) if parent else None,
                location_type=(row.get("location_type") or "").strip(),
            )

        for row in read_csv(archive, "trips.txt"):
            trip_id = intern(row["trip_id"].strip())
            route_id = intern(row["route_id"].strip())
            if route_id not in routes or trip_id in trips:
                continue
            try:
                direction = int(row.get("direction_id") or "0")
            except ValueError:
                direction = 0
            service = row.get("service_id") or ""
            headsign = (row.get("trip_headsign") or "").strip()
            trips[trip_id] = TripRec(route_id, direction, headsign, "Weekday" in service)


def consume_stop_times(path: Path, trips: dict[str, TripRec], patterns: dict[tuple[str, int, tuple[str, ...]], PatternAccum]) -> int:
    rows = 0

    def store(trip_id: str, batch: list[tuple[str, int]]) -> None:
        trip = trips.get(trip_id)
        if trip is None or len(batch) < 2:
            return
        stop_ids = tuple(stop_id for stop_id, _ in batch)
        key = (trip.route_id, trip.direction, stop_ids)
        start = batch[0][1]
        noon = abs((start % 86400) - 12 * 3600)
        weight = 3 if trip.weekday else 1
        accum = patterns.get(key)
        if accum is None:
            base = batch[0][1]
            times = [max(0, stamp - base) for _, stamp in batch]
            patterns[key] = PatternAccum(
                stops=stop_ids,
                count=weight,
                times=times,
                headsign=trip.headsign,
                noon_score=noon,
                weekday_sample=trip.weekday,
            )
            return
        accum.count += weight
        better_noon = noon < accum.noon_score
        prefer_weekday = trip.weekday and not accum.weekday_sample
        if prefer_weekday or (better_noon and (trip.weekday or not accum.weekday_sample)):
            base = batch[0][1]
            accum.times = [max(0, stamp - base) for _, stamp in batch]
            accum.noon_score = noon
            accum.weekday_sample = accum.weekday_sample or trip.weekday
            if trip.headsign:
                accum.headsign = trip.headsign

    with zipfile.ZipFile(path) as archive:
        with archive.open("stop_times.txt") as raw:
            header = raw.readline().decode("utf-8-sig").strip().replace("\r", "")
            columns = header.split(",")
            try:
                trip_i = columns.index("trip_id")
                stop_i = columns.index("stop_id")
                arr_i = columns.index("arrival_time")
                dep_i = columns.index("departure_time")
            except ValueError as error:
                raise SystemExit(f"{path} stop_times.txt missing columns: {error}") from error
            batch: list[tuple[str, int]] = []
            active: str | None = None
            for line in raw:
                rows += 1
                text = line.decode("utf-8").strip().replace("\r", "")
                if not text:
                    continue
                parts = text.split(",")
                if len(parts) <= max(trip_i, stop_i, arr_i, dep_i):
                    continue
                trip_id = parts[trip_i]
                if active is None:
                    active = trip_id
                elif trip_id != active:
                    store(active, batch)
                    batch = []
                    active = trip_id
                stamp = parse_hms(parts[dep_i]) or parse_hms(parts[arr_i])
                if stamp is None:
                    continue
                batch.append((intern(parts[stop_i]), stamp))
            if active is not None:
                store(active, batch)
    return rows


def smooth_times(stop_ids: tuple[str, ...], times: list[int], stops: dict[str, StopRec], mode: str) -> list[int]:
    speed = 8.0 if mode == "subway" else 4.2
    if not times or len(times) != len(stop_ids):
        times = [0] * len(stop_ids)
    cumulative = [0]
    for index in range(1, len(stop_ids)):
        delta = times[index] - times[index - 1] if index < len(times) else 0
        previous = stops.get(stop_ids[index - 1])
        current = stops.get(stop_ids[index])
        distance = 0.0
        if previous and current:
            distance = haversine(previous.lat, previous.lon, current.lat, current.lon)
        estimate = max(25, int(distance / speed)) if distance > 30 else 30
        if delta < 20 or delta > 1500:
            delta = estimate
        cumulative.append(cumulative[-1] + delta)
    return cumulative


def select_patterns(group: list[PatternAccum]) -> list[PatternAccum]:
    ranked = sorted(group, key=lambda item: (-item.count, -len(item.stops)))
    if not ranked:
        return []
    chosen: list[PatternAccum] = [ranked[0]]
    covered = set(ranked[0].stops)
    for candidate in ranked[1:8]:
        if len(chosen) >= 3:
            break
        if candidate.count < max(4, ranked[0].count * 0.08):
            continue
        fresh = [stop for stop in candidate.stops if stop not in covered]
        if len(fresh) >= 3:
            chosen.append(candidate)
            covered.update(candidate.stops)
    return chosen


def route_sort_key(route_id: str, mode: str) -> tuple:
    if mode == "subway":
        return (0, ORDER_INDEX.get(route_id, 500), route_id)
    if mode == "expressBus":
        return (1, route_id)
    return (2, route_id)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gtfs", type=Path, default=Path("/tmp/mta-gtfs"))
    parser.add_argument("--out", type=Path, default=Path("WYA/Resources/transit-index.json"))
    args = parser.parse_args()

    started = time.time()
    stops: dict[str, StopRec] = {}
    routes: dict[str, RouteRec] = {}
    trips: dict[str, TripRec] = {}
    used_feeds = []
    for name, filename, url in FEEDS:
        path = args.gtfs / filename
        if not path.exists():
            raise SystemExit(f"Missing {path}. Download official GTFS zips first.")
        print(f"loading tables {filename}", flush=True)
        load_feed(path, stops, routes, trips)
        used_feeds.append({"name": name, "url": url})
    print(f"stops {len(stops):,} routes {len(routes):,} trips {len(trips):,}", flush=True)

    patterns: dict[tuple[str, int, tuple[str, ...]], PatternAccum] = {}
    for name, filename, _url in FEEDS:
        path = args.gtfs / filename
        print(f"scanning stop_times {filename}", flush=True)
        rows = consume_stop_times(path, trips, patterns)
        print(f"  rows {rows:,} unique patterns {len(patterns):,}", flush=True)

    grouped: dict[tuple[str, int], list[PatternAccum]] = defaultdict(list)
    for (route_id, direction, _stops), accum in patterns.items():
        grouped[(route_id, direction)].append(accum)

    selected: list[tuple[str, int, PatternAccum]] = []
    for (route_id, direction), group in grouped.items():
        for accum in select_patterns(group):
            selected.append((route_id, direction, accum))
    print(f"selected patterns {len(selected):,}", flush=True)

    routes_for_stop: dict[str, set[str]] = defaultdict(set)
    kept_stop_ids: set[str] = set()
    pattern_rows = []
    for route_id, direction, accum in selected:
        route = routes[route_id]
        usable = [stop_id for stop_id in accum.stops if stop_id in stops]
        if len(usable) < 2:
            continue
        time_map = {stop_id: accum.times[index] for index, stop_id in enumerate(accum.stops) if index < len(accum.times)}
        times = [time_map.get(stop_id, 0) for stop_id in usable]
        smoothed = smooth_times(tuple(usable), times, stops, route.mode)
        for stop_id in usable:
            kept_stop_ids.add(stop_id)
            routes_for_stop[stop_id].add(route_id)
            parent = stops[stop_id].parent
            if parent and parent in stops:
                kept_stop_ids.add(parent)
                routes_for_stop[parent].add(route_id)
        pattern_rows.append(
            {
                "route": route_id,
                "direction": direction,
                "headsign": accum.headsign or route.short_name,
                "stops": [{"id": stop_id, "t": smoothed[index]} for index, stop_id in enumerate(usable)],
            }
        )

    def sort_route_ids(ids: set[str]) -> list[str]:
        return sorted(ids, key=lambda route_id: route_sort_key(route_id, routes[route_id].mode))

    stop_rows = []
    for stop_id in sorted(kept_stop_ids):
        stop = stops[stop_id]
        serving = routes_for_stop.get(stop_id, set())
        if not serving and not any(other.parent == stop_id for other in (stops[s] for s in kept_stop_ids if stops[s].parent)):
            continue
        modes = {routes[route_id].mode for route_id in serving}
        if "subway" in modes or stop.location_type == "1":
            mode = "subway"
        elif modes == {"expressBus"}:
            mode = "expressBus"
        else:
            mode = "localBus"
        parent = stop.parent if stop.parent in stops else None
        subway_platform = mode == "subway" and parent is not None and stops[parent].location_type == "1"
        if subway_platform and parent not in kept_stop_ids:
            subway_platform = False
        stop_rows.append(
            {
                "id": stop_id,
                "name": stop.name,
                "lat": round(stop.lat, 6),
                "lon": round(stop.lon, 6),
                "mode": mode,
                "routes": sort_route_ids(serving),
                "display": not subway_platform,
                **({"parent": parent} if parent else {}),
            }
        )

    used_route_ids = {row["route"] for row in pattern_rows}
    route_rows = []
    for route_id in sorted(used_route_ids, key=lambda item: route_sort_key(item, routes[item].mode)):
        route = routes[route_id]
        route_rows.append(
            {
                "id": route_id,
                "shortName": route.short_name,
                "longName": route.long_name,
                "mode": route.mode,
                "color": route.color,
                "textColor": route.text_color,
            }
        )

    pattern_rows.sort(key=lambda row: (route_sort_key(row["route"], routes[row["route"]].mode), row["direction"], row["headsign"]))
    document = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "Derived from official MTA GTFS static feeds for trip search and nearby stops. Arrival times come from GTFS-RT and Bus Time, not from this file.",
        "feeds": used_feeds,
        "stops": stop_rows,
        "routes": route_rows,
        "patterns": pattern_rows,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    args.out.write_bytes(encoded)
    display_stops = sum(1 for row in stop_rows if row["display"])
    print(
        f"wrote {args.out} bytes={len(encoded):,} stops={len(stop_rows):,} "
        f"display={display_stops:,} routes={len(route_rows):,} patterns={len(pattern_rows):,} "
        f"in {time.time() - started:.1f}s"
    )


if __name__ == "__main__":
    main()
