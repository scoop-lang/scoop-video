"""Compare the probe's frame identities with one Metal System Trace recording."""

import csv
import json
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zlib
from collections import Counter, defaultdict
from fractions import Fraction
from pathlib import Path


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def export(trace, *selector):
    return ET.fromstring(
        subprocess.check_output(
            ["xcrun", "xctrace", "export", "--input", trace, *selector]
        )
    )


def rows(trace, schema, process=None):
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    node = export(trace, "--xpath", xpath).find("node")
    require(node is not None, f"Missing Instruments table {schema}")
    # xctrace interns cells, including process records nested inside thread records.
    ids = {el.attrib["id"]: el for el in node.iter() if "id" in el.attrib}
    columns = [col.findtext("mnemonic") for col in node.findall("./schema/col")]
    result = []
    for row in node.findall("row"):
        cells = [ids[el.attrib["ref"]] if "ref" in el.attrib else el for el in row]
        values = {k: (el.text or el.get("fmt", "")) for k, el in zip(columns, cells)}
        if process is None or values["process"] == process:
            result.append(values)
    return result


def check_playback(folder):
    trace = folder / "playback.trace"
    target = export(trace, "--toc").find("./run/info/target/process")
    require(
        target is not None and target.get("return-exit-status") == "0",
        "Player did not exit successfully",
    )
    process = f"{target.attrib['name']} ({target.attrib['pid']})"
    with (folder / "playback-frames.csv").open() as fp:
        frames = [f for f in csv.DictReader(fp) if f.get("accepted", "1") == "1"]
    encoders = sorted(
        rows(trace, "metal-application-encoders-list", process),
        key=lambda e: int(e["start"]),
    )
    buffers = {
        r["cmdbuffer-id"]: r
        for r in rows(trace, "metal-application-command-buffer-submissions", process)
    }
    presents = sorted(
        rows(trace, "ca-client-present-request", process),
        key=lambda r: int(buffers[r["cmdbuffer-id"]]["start"]),
    )
    callbacks = rows(trace, "ca-client-presented-handler", process)
    errors = rows(trace, "metal-command-buffer-error")
    require(
        not any(r["cmdbuffer-id"] in buffers for r in errors), "Command buffer error"
    )
    require(
        len(presents) == len(frames) and frames,
        "UI submissions do not match Core Animation presents",
    )
    require(
        all(buffers[r["cmdbuffer-id"]]["num-encoders"] == "0" for r in presents),
        "An encoder used the present buffer",
    )
    actual_counts = Counter(e["cmdbuffer-id"] for e in encoders)
    require(
        all(actual_counts[k] == int(b["num-encoders"]) for k, b in buffers.items()),
        "Missing application encoders",
    )

    accesses = defaultdict(list)
    for r in rows(trace, "metal-io-surface-access", process):
        accesses[r["encoder-id"]].append(r)
    channels = defaultdict(set)
    for r in rows(trace, "metal-gpu-intervals", process):
        channels[r["encoder-id"]].add(r["channel-name"])

    joined = []
    ticks = []
    steady = []
    startup_encoders = []
    startup_frames = 0
    render_channels = {"Vertex", "Fragment"}
    i = 0
    # Surface flushes the canvas before creating its present command buffer. The
    # CPU creation timestamps delimit frames even with several GPU frames in flight.
    for f, present in zip(frames, presents):
        boundary = int(buffers[present["cmdbuffer-id"]]["start"])
        first = i
        while i < len(encoders) and int(encoders[i]["start"]) < boundary:
            i += 1
        batch = encoders[first:i]
        target_id = present["surface-id"]
        if not int(f["iosurface"]):
            require(not ticks, "Unexpected empty frame during video")
            startup_frames += 1
            for e in batch:
                io = accesses[e["encoder-id"]]
                require(
                    all(
                        r["surface-id"] == target_id and r["access-type"] == "1"
                        for r in io
                    ),
                    "Unexpected surface in the startup pass",
                )
                startup_encoders.append(
                    {
                        "encoder": e["encoder-label"],
                        "channels": sorted(channels[e["encoder-id"]]),
                        "drawable_writes": len(io),
                    }
                )
            continue

        tick = 60 * Fraction(int(f["pts_value"]), int(f["pts_scale"]))
        require(
            tick.denominator == 1 and 0 <= tick < 540, f"Unexpected source PTS {tick}"
        )
        require(
            len(batch) == 1 and batch[0]["encoder-label"].startswith("Render Command"),
            f"Extra video encoder at PTS {tick}",
        )
        e = batch[0]
        io = accesses[e["encoder-id"]]
        require(
            len(io) == 2
            and all(
                r["cmdbuffer-id"] == e["cmdbuffer-id"]
                and (r["width"], r["height"]) == ("3840", "2160")
                for r in io
            ),
            f"Expected two 4K surface accesses in the draw at PTS {tick}",
        )
        expected = {("0", f["iosurface"]), ("1", target_id)}
        require(
            {(r["access-type"], r["surface-id"]) for r in io} == expected
            and f["iosurface"] != target_id
            and target_id == f.get("drawable_iosurface", target_id),
            f"NV12/drawable identity mismatch at PTS {tick}",
        )
        require(
            channels[e["encoder-id"]] == render_channels,
            f"Unexpected GPU channels in the video draw at PTS {tick}",
        )
        ticks.append(int(tick))
        if 120 <= tick < 480:
            steady.append(float(f["host_s"]))
        joined.append(
            (
                int(tick),
                f["iosurface"],
                target_id,
                e["encoder-id"],
                e["cmdbuffer-id"],
                present["cmdbuffer-id"],
            )
        )
    require(
        i == len(encoders) and set(accesses) <= {e["encoder-id"] for e in encoders},
        "Unaccounted encoder or IOSurface access",
    )
    require(len(steady) > 1, "Missing steady video interval")
    require(ticks == sorted(ticks), "Playback PTS went backwards")
    with (folder / "encoder-frames.csv").open("w", newline="") as fp:
        writer = csv.writer(fp)
        writer.writerow(
            [
                "pts_60hz",
                "read_iosurface",
                "write_iosurface",
                "encoder_id",
                "render_cmd",
                "present_cmd",
            ]
        )
        writer.writerows(joined)
    return {
        "target": target.attrib["name"],
        "frames": len(ticks),
        "distinct_pts": len(set(ticks)),
        "missing_pts_60hz": sorted(set(range(540)) - set(ticks)),
        "source_iosurfaces": len({r[1] for r in joined}),
        "drawable_iosurfaces": len({r[2] for r in joined}),
        "steady_frames_2_to_8_s": len(steady),
        "steady_submit_fps": round((len(steady) - 1) / (steady[-1] - steady[0]), 3),
        "render_encoders": len(joined),
        "gpu_channels": sorted(render_channels),
        "all_encoder_labels": dict(Counter(e["encoder-label"] for e in encoders)),
        "startup_frames": startup_frames,
        "before_first_video_frame": startup_encoders,
        "present_requests": len(presents),
        "presented_handler_events_before_exit": len(callbacks),
        "matched_read_write_pairs": len(joined),
    }


def extract_shader(folder, ui):
    capture = folder / "frame.gputrace"
    meta = plistlib.loads((capture / "metadata").read_bytes())
    require(
        meta["DYCaptureEngine.captured_frames_count"] == 1,
        "Expected a one-frame GPU capture",
    )
    video = controls = None
    # Xcode 27.2 stores generated MSL in zlib members. The capture also opens in Xcode.
    for store in capture.glob("store[0-9]*"):
        data = store.read_bytes()
        for member in re.finditer(rb"\x78[\x01\x5e\x9c\xda]", data):
            try:
                msl = zlib.decompress(data[member.start() :]).rstrip(b"\0")
            except zlib.error:
                continue
            if b"fragment Outputs fragmentMain" not in msl:
                continue
            if (
                b"_out.sk_FragColor = outputColor_S0;" in msl
                and b"[[texture(" not in msl
            ):
                controls = msl
            if all(
                s in msl
                for s in [
                    b"fragment Outputs fragmentMain",
                    b"[[texture(0)]]",
                    b"[[texture(1)]]",
                    b"sample(_globals.uTextureSampler_0",
                    b"sample(_globals.uTextureSampler_1",
                    b"uchromaOffset" if ui else b"ucolorSpaceMatrix",
                    b"_out.sk_FragColor",
                ]
            ):
                video = msl
    require(
        video is not None, "Two-plane Skia fragment program not found in the capture"
    )
    (folder / "captured-fragment.metal").write_bytes(video)
    if ui:
        require(
            controls is not None and b"encodeSRGB" in video and b"1.5748" in video,
            "Missing UI controls or BT.709 video pipeline",
        )
        (folder / "captured-controls.metal").write_bytes(controls)


def cpu_counts(log):
    line = next((s for s in log.splitlines() if s.startswith("cpu_access ")), None)
    require(line is not None, "No CPU probe counters")
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}


def check_cpu(folder):
    log = (folder / "audit.log").read_text()
    counters = cpu_counts(log)
    positive = cpu_counts((folder / "control.log").read_text())
    with (folder / "audit-frames.csv").open() as fp:
        frames = [f for f in csv.DictReader(fp) if int(f["iosurface"])]
    wrapped = set(
        re.findall(
            r"^wrap surface=(\d+) format=0x34323076 caller=pixelBufferRecipient_copyCVPixelBufferFromXPCComponents$",
            log,
            re.MULTILINE,
        )
    )
    require(
        all(f["iosurface"] in wrapped for f in frames) and len(frames) > 0,
        "Output frame not in decoder XPC IOSurface pool",
    )
    require(
        counters["views"] == sum(int(f.get("new_sample", "1")) for f in frames) * 2
        and counters["other_texture_class"] == 0,
        "Texture class coverage incomplete",
    )
    for key in [
        "cv_lock",
        "cv_base",
        "cv_plane_base",
        "io_lock",
        "metal_get_bytes",
        "metal_replace_region",
        "vt_transfer",
    ]:
        require(
            positive[key] > 0 and counters[key] == 0,
            f"CPU access/control results changed for {key}",
        )
    callers = Counter()
    for n, symbol in re.findall(
        r"IOSurfaceGetBaseAddressOfPlane stack count=(\d+)\n[^\n]+\n1\s+\S+\s+0x[0-9a-f]+ (.+?) \+ \d+",
        log,
    ):
        callers[symbol] += int(n)
    require(
        sum(callers.values()) == counters["io_plane_base"],
        "Incomplete plane-lookup stacks",
    )
    base_queries = re.findall(
        r"^whole-base surface=(\d+) format=(\w+)$", log, re.MULTILINE
    )
    require(
        len(base_queries) == counters["io_base"] and positive["io_base"] > 0,
        "Incomplete whole-surface lookup observations",
    )
    require(
        all(
            surface not in wrapped and fmt == "0x42475241"
            for surface, fmt in base_queries
        ),
        "Whole-base lookup of video pixels",
    )
    return {
        "frames": len(frames),
        "source_iosurfaces_from_decoder_xpc": len(wrapped),
        "pixel_api_counts": counters,
        "plane_lookup_callers": callers,
        "whole_base_bgra_surface_ids": sorted(
            {int(surface) for surface, _ in base_queries}
        ),
        "blits_observed": [
            line for line in log.splitlines() if line.startswith("blit ")
        ],
        "positive_control": positive,
    }


if __name__ == "__main__":
    require(
        len(sys.argv) == 2, "Usage: python3 scripts/check-trace.py RECORDING_DIRECTORY"
    )
    folder = Path(sys.argv[1])
    result = {
        "metal_system_trace": check_playback(folder),
        "cpu_audit": check_cpu(folder),
    }
    extract_shader(folder, result["metal_system_trace"]["target"] == "scoop-video-ui")
    report = json.dumps(result, indent=2)
    (folder / "summary.json").write_text(report + "\n")
    print(report)
