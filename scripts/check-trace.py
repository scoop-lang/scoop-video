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
        "Playback did not exit successfully",
    )
    process = f"{target.attrib['name']} ({target.attrib['pid']})"
    with (folder / "playback-frames.csv").open() as fp:
        frames = list(csv.DictReader(fp))
    ticks = [60 * Fraction(int(f["pts_value"]), int(f["pts_scale"])) for f in frames]
    require(ticks and all(t.denominator == 1 for t in ticks), "Unexpected frame PTS")
    require(
        ticks == sorted(set(ticks)) and 0 <= ticks[0] <= ticks[-1] < 540,
        "Frame PTS outside the sample or out of order",
    )

    enc = sorted(
        rows(trace, "metal-application-encoders-list", process),
        key=lambda r: int(r["start"]),
    )
    buffers = rows(trace, "metal-application-command-buffer-submissions", process)
    errors = rows(trace, "metal-command-buffer-error")
    present = sorted(
        rows(trace, "ca-client-present-request", process),
        key=lambda r: int(r["timestamp"]),
    )
    callbacks = rows(trace, "ca-client-presented-handler", process)
    gpu = rows(trace, "metal-gpu-intervals", process)
    accesses = defaultdict(list)
    for r in rows(trace, "metal-io-surface-access", process):
        accesses[r["encoder-id"]].append(r)

    count = len(frames)
    require(
        len(enc) == len(accesses) == len(present) == count,
        "Per-frame render/access/present counts differ",
    )
    require(
        all(r["encoder-label"] == "Render Command 0" for r in enc),
        "Found another encoder",
    )
    channels = sorted({r["channel-name"] for r in gpu})
    require(
        set(channels) == {"Vertex", "Fragment"}, f"Unexpected GPU channels: {channels}"
    )
    render_buffers = {r["cmdbuffer-id"] for r in buffers if r["num-encoders"] == "1"}
    present_buffers = {
        r["cmdbuffer-id"]
        for r in buffers
        if r["num-encoders"] == "0" and '"Present only"' in r["event-label"]
    }
    require(
        render_buffers == {r["cmdbuffer-id"] for r in enc}
        and present_buffers == {r["cmdbuffer-id"] for r in present}
        and len(buffers) == 2 * count,
        "Unexpected command buffer submissions",
    )
    require(
        not any(r["cmdbuffer-id"] in render_buffers | present_buffers for r in errors),
        "Command buffer error",
    )

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
        for tick, f, e, p in zip(ticks, frames, enc, present):
            io = accesses[e["encoder-id"]]
            expected = {("0", f["iosurface"]), ("1", f["drawable_iosurface"])}
            observed = {(r["access-type"], r["surface-id"]) for r in io}
            require(
                len(io) == 2
                and observed == expected
                and f["iosurface"] != f["drawable_iosurface"]
                and all(
                    r["cmdbuffer-id"] == e["cmdbuffer-id"]
                    and (r["width"], r["height"]) == ("3840", "2160")
                    for r in io
                )
                and p["surface-id"] == f["drawable_iosurface"],
                f"IOSurface handoff mismatch at frame {tick}",
            )
            writer.writerow(
                [
                    tick,
                    f["iosurface"],
                    f["drawable_iosurface"],
                    e["encoder-id"],
                    e["cmdbuffer-id"],
                    p["cmdbuffer-id"],
                ]
            )

    steady = [float(f["host_s"]) for t, f in zip(ticks, frames) if 120 <= t < 480]
    require(len(steady) > 1, "No steady-state sample")
    return {
        "frames": count,
        "missing_pts_60hz": sorted(set(range(540)) - set(ticks)),
        "source_iosurfaces": len({f["iosurface"] for f in frames}),
        "drawable_iosurfaces": len({f["drawable_iosurface"] for f in frames}),
        "steady_frames_2_to_8_s": len(steady),
        "steady_submit_fps": round((len(steady) - 1) / (steady[-1] - steady[0]), 3),
        "render_encoders": len(enc),
        "gpu_channels": channels,
        "present_requests": len(present),
        "presented_handler_events_before_exit": len(callbacks),
        "matched_read_write_pairs": len(enc),
    }


def extract_shader(folder):
    capture = folder / "frame.gputrace"
    meta = plistlib.loads((capture / "metadata").read_bytes())
    require(
        meta["DYCaptureEngine.captured_frames_count"] == 1,
        "Expected a one-frame GPU capture",
    )
    # Xcode 27.2 stores generated MSL in zlib members. The capture also opens in Xcode.
    for store in capture.glob("store[0-9]*"):
        data = store.read_bytes()
        for member in re.finditer(rb"\x78[\x01\x5e\x9c\xda]", data):
            try:
                msl = zlib.decompress(data[member.start() :]).rstrip(b"\0")
            except zlib.error:
                continue
            if all(
                s in msl
                for s in [
                    b"fragment Outputs fragmentMain",
                    b"[[texture(0)]]",
                    b"[[texture(1)]]",
                    b"sample(_globals.uTextureSampler_0",
                    b"sample(_globals.uTextureSampler_1",
                    b"ucolorSpaceMatrix",
                    b"_out.sk_FragColor",
                ]
            ):
                (folder / "captured-fragment.metal").write_bytes(msl)
                return
    raise SystemExit("Two-plane Skia fragment program not found in the capture")


def cpu_counts(log):
    line = next((s for s in log.splitlines() if s.startswith("cpu_access ")), None)
    require(line is not None, "No CPU probe counters")
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}


def check_cpu(folder):
    log = (folder / "audit.log").read_text()
    counters = cpu_counts(log)
    positive = cpu_counts((folder / "control.log").read_text())
    with (folder / "audit-frames.csv").open() as fp:
        frames = list(csv.DictReader(fp))
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
        counters["views"] == len(frames) * 2 and counters["other_texture_class"] == 0,
        "Texture class coverage incomplete",
    )
    for key in [
        "cv_lock",
        "cv_base",
        "cv_plane_base",
        "io_lock",
        "io_base",
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
        r"stack count=(\d+)\n[^\n]+\n1\s+\S+\s+0x[0-9a-f]+ (.+?) \+ \d+", log
    ):
        callers[symbol] += int(n)
    require(
        sum(callers.values()) == counters["io_plane_base"],
        "Incomplete plane-lookup stacks",
    )
    return {
        "frames": len(frames),
        "source_iosurfaces_from_decoder_xpc": len(wrapped),
        "pixel_api_counts": counters,
        "plane_lookup_callers": callers,
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
    extract_shader(folder)
    report = json.dumps(result, indent=2)
    (folder / "summary.json").write_text(report + "\n")
    print(report)
