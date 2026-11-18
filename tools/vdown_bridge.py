#!/usr/bin/env python3
"""
VDown Companion Bridge Server for HarmonyOS & Remote Clients.

Exposes yt-dlp + FFmpeg over HTTP on LAN so the HarmonyOS VDown app (or any
HTTP client) can parse and record YouTube Live / Bilibili / 1800+ sites with
real-time fragmented MP4 recording and arbitrary-timestamp checkpoint saving.

Usage:
  python tools/vdown_bridge.py --port 8765
"""

from __future__ import annotations

import argparse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
from typing import Any
from urllib.parse import parse_qs, urlparse
import uuid


def _find_binary(name: str, extra_candidates: list[str] | None = None) -> str:
    found = shutil.which(name)
    if found:
        return found
    for candidate in extra_candidates or []:
        if candidate and os.path.isfile(candidate):
            return candidate
    return name


def _format_bytes(num_bytes: float) -> str:
    if num_bytes < 1024:
        return f"{int(num_bytes)} B"
    if num_bytes < 1024 * 1024:
        return f"{num_bytes / 1024:.1f} KB"
    if num_bytes < 1024 * 1024 * 1024:
        return f"{num_bytes / (1024 * 1024):.1f} MB"
    return f"{num_bytes / (1024 * 1024 * 1024):.2f} GB"


def _format_duration(seconds: int) -> str:
    if seconds < 0:
        seconds = 0
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    if h > 0:
        return f"{h:02d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def _sanitize_filename(title: str) -> str:
    cleaned = re.sub(r'[\\/:*?"<>|\r\n]+', "_", title)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if not cleaned:
        return "vdown_media"
    return cleaned[:80]


def _make_display_label(fmt: dict[str, Any]) -> str:
    height = fmt.get("height")
    fps = fmt.get("fps")
    note = str(fmt.get("format_note") or "").strip()
    ext = str(fmt.get("ext") or "mp4")
    if isinstance(height, (int, float)) and height > 0:
        label = f"{int(height)}p"
        if isinstance(fps, (int, float)) and fps > 30:
            label += f"{int(fps)}"
        return label
    if note:
        return note
    return f"{fmt.get('format_id', 'best')} ({ext})"


class TaskState:
    def __init__(self, task_id: str, params: dict[str, Any]) -> None:
        self.task_id = task_id
        self.url = str(params.get("url") or "").strip()
        self.title = str(params.get("title") or "VDown_Task")
        self.format_selector = str(params.get("format_selector") or "best")
        self.audio_only = bool(params.get("audio_only", False))
        self.is_live = bool(params.get("is_live", False))
        self.live_from_start = bool(params.get("live_from_start", False))
        self.max_duration_seconds = int(params.get("max_duration_seconds") or 0)

        self.status = "recording" if self.is_live else "running"
        self.progress = 0.0
        self.recorded_duration = ""
        self.recorded_size = ""
        self.bitrate = ""
        self.speed = ""
        self.total_size = ""
        self.segment_index = 1
        self.saved_files: list[str] = []
        self.output_file = ""
        self.error = ""

        self.lock = threading.Lock()
        self.control_mode = "none"  # none | stop | split | cancel
        self.split_event = threading.Event()
        self.last_split_file: str | None = None
        self.active_ffmpeg: subprocess.Popen[bytes] | None = None
        self.active_ytdlp: subprocess.Popen[bytes] | None = None

    def to_status_dict(self) -> dict[str, Any]:
        with self.lock:
            return {
                "task_id": self.task_id,
                "status": self.status,
                "progress": self.progress,
                "recorded_duration": self.recorded_duration,
                "recorded_size": self.recorded_size,
                "bitrate": self.bitrate,
                "speed": self.speed,
                "total_size": self.total_size,
                "segment_index": self.segment_index,
                "saved_files": list(self.saved_files),
                "output_file": self.output_file,
                "error": self.error,
            }


class BridgeEngine:
    def __init__(
        self,
        ytdlp_bin: str,
        ffmpeg_bin: str,
        output_dir: Path,
        proxy: str = "",
        cookies_from_browser: str = "",
    ) -> None:
        self.ytdlp_bin = ytdlp_bin
        self.ffmpeg_bin = ffmpeg_bin
        self.output_dir = output_dir.resolve()
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.proxy = proxy.strip()
        self.cookies_from_browser = cookies_from_browser.strip()
        self.tasks: dict[str, TaskState] = {}
        self.tasks_lock = threading.Lock()

    def _base_ytdlp_args(self) -> list[str]:
        args = ["--no-warnings"]
        if self.proxy:
            args.extend(["--proxy", self.proxy])
        if self.cookies_from_browser:
            args.extend(["--cookies-from-browser", self.cookies_from_browser])
        return args

    def fetch_info(self, url: str) -> dict[str, Any]:
        cmd = [
            self.ytdlp_bin,
            *self._base_ytdlp_args(),
            "--dump-single-json",
            "--skip-download",
            url,
        ]
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60,
        )
        if proc.returncode != 0:
            err = proc.stderr.strip() or proc.stdout.strip() or "yt-dlp failed"
            raise RuntimeError(err)

        raw = json.loads(proc.stdout)
        live_status = str(raw.get("live_status") or "")
        is_live = bool(raw.get("is_live")) or live_status == "is_live"
        webpage = str(raw.get("webpage_url") or url)
        extractor = str(raw.get("extractor") or raw.get("extractor_key") or "yt-dlp")
        is_youtube = "youtube" in extractor.lower() or "youtu" in webpage.lower()

        formats_out: list[dict[str, Any]] = []
        seen_ids: set[str] = set()
        for fmt in raw.get("formats") or []:
            fid = str(fmt.get("format_id") or "")
            if not fid or fid in seen_ids:
                continue
            vcodec = str(fmt.get("vcodec") or "")
            acodec = str(fmt.get("acodec") or "")
            if vcodec == "none":
                continue
            seen_ids.add(fid)
            formats_out.append(
                {
                    "format_id": fid,
                    "ext": str(fmt.get("ext") or "mp4"),
                    "height": fmt.get("height") or 0,
                    "fps": fmt.get("fps") or 0,
                    "vcodec": vcodec,
                    "acodec": acodec,
                    "filesize": fmt.get("filesize") or fmt.get("filesize_approx") or 0,
                    "tbr": fmt.get("tbr") or 0,
                    "format_note": str(fmt.get("format_note") or ""),
                    "quality": fmt.get("quality") or 0,
                    "display_label": _make_display_label(fmt),
                }
            )

        formats_out.sort(
            key=lambda f: (float(f.get("height") or 0), float(f.get("tbr") or 0)),
            reverse=True,
        )

        return {
            "id": str(raw.get("id") or ""),
            "title": str(raw.get("title") or "未命名视频"),
            "uploader": str(raw.get("uploader") or raw.get("channel") or ""),
            "thumbnail": str(raw.get("thumbnail") or ""),
            "duration": int(raw.get("duration") or 0),
            "webpage_url": webpage,
            "extractor": extractor,
            "is_live": is_live,
            "is_youtube": is_youtube,
            "formats": formats_out,
        }

    def start_task(self, params: dict[str, Any]) -> str:
        task_id = uuid.uuid4().hex[:12]
        task = TaskState(task_id, params)
        if not task.url:
            raise ValueError("Missing url")
        with self.tasks_lock:
            self.tasks[task_id] = task

        target = self._run_live_task if task.is_live else self._run_vod_task
        thread = threading.Thread(target=target, args=(task,), daemon=True)
        thread.start()
        return task_id

    def get_status(self, task_id: str) -> dict[str, Any]:
        with self.tasks_lock:
            task = self.tasks.get(task_id)
        if not task:
            return {"error": f"Unknown task_id: {task_id}"}
        return task.to_status_dict()

    def stop_task(self, task_id: str) -> dict[str, Any]:
        with self.tasks_lock:
            task = self.tasks.get(task_id)
        if not task:
            return {"error": f"Unknown task_id: {task_id}"}
        with task.lock:
            if task.status in ("done", "error", "canceled"):
                return task.to_status_dict()
            task.control_mode = "stop"
            if task.is_live:
                task.status = "finalizing"
            ff = task.active_ffmpeg
            yt = task.active_ytdlp
        self._graceful_stop_procs(ff, yt)
        return task.to_status_dict()

    def split_task(self, task_id: str) -> dict[str, Any]:
        with self.tasks_lock:
            task = self.tasks.get(task_id)
        if not task:
            return {"error": f"Unknown task_id: {task_id}"}
        with task.lock:
            if not task.is_live or task.status != "recording":
                return {"error": "Task is not actively recording"}
            task.split_event.clear()
            task.last_split_file = None
            task.control_mode = "split"
            ff = task.active_ffmpeg
            yt = task.active_ytdlp
        self._graceful_stop_procs(ff, yt)
        if task.split_event.wait(timeout=30.0) and task.last_split_file:
            return {"saved_file": task.last_split_file}
        return {"error": "Split checkpoint timed out"}

    def cancel_task(self, task_id: str) -> dict[str, Any]:
        with self.tasks_lock:
            task = self.tasks.get(task_id)
        if not task:
            return {"error": f"Unknown task_id: {task_id}"}
        with task.lock:
            task.control_mode = "cancel"
            ff = task.active_ffmpeg
            yt = task.active_ytdlp
        self._graceful_stop_procs(ff, yt)
        return task.to_status_dict()

    def is_allowed_file(self, candidate: Path) -> bool:
        try:
            resolved = candidate.resolve()
        except OSError:
            return False
        if resolved.is_file() and (
            resolved == self.output_dir or self.output_dir in resolved.parents
        ):
            return True
        return False

    def _graceful_stop_procs(
        self,
        ff: subprocess.Popen[bytes] | None,
        yt: subprocess.Popen[bytes] | None,
    ) -> None:
        if yt is not None and yt.poll() is None:
            # Pipe mode: stop yt-dlp so FFmpeg receives EOF on pipe:0 cleanly.
            try:
                if ff is not None and yt.stdout is not None:
                    yt.terminate()
                else:
                    yt.terminate()
            except OSError:
                pass
        if ff is not None and ff.poll() is None and yt is None:
            # Direct URL mode: send FFmpeg 'q\n' on stdin to flush trailer & exit 0.
            try:
                if ff.stdin is not None:
                    ff.stdin.write(b"q\n")
                    ff.stdin.flush()
            except OSError:
                try:
                    ff.terminate()
                except OSError:
                    pass

    def _remux_faststart(self, raw_path: Path, final_path: Path) -> Path:
        if not raw_path.exists() or raw_path.stat().st_size == 0:
            return raw_path
        cmd = [
            self.ffmpeg_bin,
            "-y",
            "-v",
            "error",
            "-i",
            str(raw_path),
            "-c",
            "copy",
            "-movflags",
            "+faststart",
            str(final_path),
        ]
        proc = subprocess.run(cmd, capture_output=True, timeout=180)
        if proc.returncode == 0 and final_path.exists() and final_path.stat().st_size > 0:
            try:
                raw_path.unlink()
            except OSError:
                pass
            return final_path
        # Fall back to the crash-safe fragmented MP4 (already playable)
        if raw_path != final_path:
            try:
                shutil.move(str(raw_path), str(final_path))
                return final_path
            except OSError:
                return raw_path
        return raw_path

    def _resolve_live_stream(self, task: TaskState) -> dict[str, Any] | None:
        if task.live_from_start or self.proxy.lower().startswith("socks"):
            return None
        cmd = [
            self.ytdlp_bin,
            *self._base_ytdlp_args(),
            "-f",
            task.format_selector or "best",
            "--dump-single-json",
            "--no-playlist",
            "--skip-download",
            task.url,
        ]
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=45,
        )
        if proc.returncode != 0:
            return None
        try:
            data = json.loads(proc.stdout)
        except json.JSONDecodeError:
            return None
        direct_url = data.get("url")
        if isinstance(direct_url, str) and direct_url.startswith("http"):
            return {
                "url": direct_url,
                "headers": data.get("http_headers") or {},
            }
        req_fmts = data.get("requested_formats")
        if isinstance(req_fmts, list) and len(req_fmts) == 1:
            u = req_fmts[0].get("url")
            if isinstance(u, str) and u.startswith("http"):
                return {
                    "url": u,
                    "headers": req_fmts[0].get("http_headers") or data.get("http_headers") or {},
                }
        return None

    def _run_live_task(self, task: TaskState) -> None:
        safe_title = _sanitize_filename(task.title)
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        ext = "m4a" if task.audio_only else "mp4"
        seg_index = 1

        try:
            while True:
                suffix = "" if seg_index == 1 else f"_part{seg_index:02d}"
                raw_path = self.output_dir / f".{safe_title}_live_{stamp}{suffix}.frag.{ext}"
                final_path = self.output_dir / f"{safe_title}_live_{stamp}{suffix}.{ext}"

                with task.lock:
                    task.segment_index = seg_index
                    task.status = "recording"

                ff_args = [
                    self.ffmpeg_bin,
                    "-y",
                    "-v",
                    "warning",
                    "-stats_period",
                    "0.5",
                    "-progress",
                    "pipe:1",
                ]
                resolved = self._resolve_live_stream(task)
                use_pipe = resolved is None

                if not use_pipe and resolved is not None:
                    if self.proxy.lower().startswith("http"):
                        ff_args.extend(["-http_proxy", self.proxy])
                    headers = resolved.get("headers") or {}
                    ua = headers.get("User-Agent")
                    if ua:
                        ff_args.extend(["-user_agent", str(ua)])
                    header_lines = "".join(
                        f"{k}: {v}\r\n"
                        for k, v in headers.items()
                        if str(k).lower() != "user-agent"
                    )
                    if header_lines:
                        ff_args.extend(["-headers", header_lines])
                    ff_args.extend(
                        [
                            "-reconnect",
                            "1",
                            "-reconnect_streamed",
                            "1",
                            "-reconnect_at_eof",
                            "1",
                            "-reconnect_delay_max",
                            "10",
                            "-i",
                            resolved["url"],
                        ]
                    )
                else:
                    ff_args.extend(["-i", "pipe:0"])

                if task.max_duration_seconds > 0:
                    ff_args.extend(["-t", str(task.max_duration_seconds)])

                if task.audio_only:
                    ff_args.extend(["-vn", "-c:a", "aac", "-f", "mp4", "-movflags", "+frag_keyframe+empty_moov+default_base_moof"])
                else:
                    ff_args.extend(
                        [
                            "-c",
                            "copy",
                            "-bsf:a",
                            "aac_adtstoasc",
                            "-f",
                            "mp4",
                            "-movflags",
                            "+frag_keyframe+empty_moov+default_base_moof",
                        ]
                    )
                ff_args.append(str(raw_path))

                yt_proc: subprocess.Popen[bytes] | None = None
                if use_pipe:
                    yt_cmd = [
                        self.ytdlp_bin,
                        *self._base_ytdlp_args(),
                        "-f",
                        task.format_selector or "best",
                        "--no-part",
                        "--hls-use-mpegts",
                    ]
                    if task.live_from_start and seg_index == 1:
                        yt_cmd.append("--live-from-start")
                    yt_cmd.extend(["-o", "-", task.url])
                    yt_proc = subprocess.Popen(
                        yt_cmd,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                    )
                    ff_proc = subprocess.Popen(
                        ff_args,
                        stdin=yt_proc.stdout,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    if yt_proc.stdout is not None:
                        yt_proc.stdout.close()
                else:
                    ff_proc = subprocess.Popen(
                        ff_args,
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )

                with task.lock:
                    task.active_ffmpeg = ff_proc
                    task.active_ytdlp = yt_proc

                self._consume_ffmpeg_progress(task, ff_proc)
                ff_proc.wait()
                if yt_proc is not None:
                    try:
                        if yt_proc.poll() is None:
                            yt_proc.terminate()
                        yt_proc.wait(timeout=5)
                    except subprocess.SubprocessError:
                        pass

                with task.lock:
                    task.active_ffmpeg = None
                    task.active_ytdlp = None
                    mode = task.control_mode

                if mode == "cancel":
                    try:
                        if raw_path.exists():
                            raw_path.unlink()
                    except OSError:
                        pass
                    with task.lock:
                        task.status = "canceled"
                    return

                has_data = raw_path.exists() and raw_path.stat().st_size > 1024
                if mode == "stop":
                    with task.lock:
                        task.status = "finalizing"
                    if has_data:
                        saved = self._remux_faststart(raw_path, final_path)
                        with task.lock:
                            task.saved_files.append(str(saved))
                            task.output_file = str(saved)
                            task.progress = 1.0
                            task.status = "done"
                        return
                    with task.lock:
                        task.status = "error"
                        task.error = "录制内容为空，未能保存视频。"
                    return

                if mode == "split":
                    saved_str: str | None = None
                    if has_data:
                        saved = self._remux_faststart(raw_path, final_path)
                        saved_str = str(saved)
                        with task.lock:
                            task.saved_files.append(saved_str)
                            task.output_file = saved_str
                    with task.lock:
                        task.last_split_file = saved_str
                        task.control_mode = "none"
                    task.split_event.set()
                    seg_index += 1
                    continue

                # Natural end (live stream ended or reached max_duration_seconds)
                if has_data:
                    with task.lock:
                        task.status = "finalizing"
                    saved = self._remux_faststart(raw_path, final_path)
                    with task.lock:
                        task.saved_files.append(str(saved))
                        task.output_file = str(saved)
                        task.progress = 1.0
                        task.status = "done"
                    return

                err_msg = ""
                if ff_proc.stderr is not None:
                    err_msg = ff_proc.stderr.read().decode("utf-8", errors="replace").strip()
                with task.lock:
                    task.status = "error"
                    task.error = err_msg or f"FFmpeg exited with code {ff_proc.returncode}"
                return
        except Exception as exc:
            with task.lock:
                task.status = "error"
                task.error = str(exc)

    def _consume_ffmpeg_progress(
        self, task: TaskState, ff_proc: subprocess.Popen[bytes]
    ) -> None:
        if ff_proc.stdout is None:
            return
        fields: dict[str, str] = {}
        while True:
            raw_line = ff_proc.stdout.readline()
            if not raw_line:
                break
            line = raw_line.decode("utf-8", errors="replace").strip()
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            fields[k.strip()] = v.strip()
            if k.strip() == "progress":
                out_us = int(fields.get("out_time_us") or fields.get("out_time_ms") or "0")
                sec = max(0, out_us // 1_000_000)
                total_bytes = int(fields.get("total_size") or "0")
                bitrate = fields.get("bitrate") or ""
                if bitrate == "N/A":
                    bitrate = ""
                with task.lock:
                    task.recorded_duration = _format_duration(sec)
                    if total_bytes > 0:
                        task.recorded_size = _format_bytes(total_bytes)
                    if bitrate:
                        task.bitrate = bitrate
                fields.clear()

    def _run_vod_task(self, task: TaskState) -> None:
        safe_title = _sanitize_filename(task.title)
        template = str(self.output_dir / f"{safe_title}_%(id)s.%(ext)s")
        cmd = [
            self.ytdlp_bin,
            *self._base_ytdlp_args(),
            "--newline",
            "--no-playlist",
            "--print",
            "after_move:filepath",
        ]
        if task.audio_only:
            cmd.extend(["-x", "--audio-format", "mp3"])
        else:
            cmd.extend(["-f", task.format_selector or "bestvideo+bestaudio/best", "--merge-output-format", "mp4"])
        cmd.extend(["-o", template, task.url])

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            with task.lock:
                task.active_ytdlp = proc

            pct_re = re.compile(r"\[download\]\s+(\d+(?:\.\d+)?)%\s+of\s+~?\s*(\S+)\s+at\s+(\S+)")
            last_path = ""
            if proc.stdout is not None:
                for raw_line in proc.stdout:
                    line = raw_line.decode("utf-8", errors="replace").strip()
                    m = pct_re.search(line)
                    if m:
                        with task.lock:
                            task.progress = min(1.0, float(m.group(1)) / 100.0)
                            task.total_size = m.group(2)
                            task.speed = m.group(3)
                    elif line and not line.startswith("[") and os.path.isfile(line):
                        last_path = line

            code = proc.wait()
            with task.lock:
                task.active_ytdlp = None
                if task.control_mode == "cancel":
                    task.status = "canceled"
                    return
                if code == 0 and last_path:
                    task.output_file = last_path
                    task.saved_files = [last_path]
                    task.progress = 1.0
                    task.status = "done"
                elif code == 0:
                    task.progress = 1.0
                    task.status = "done"
                else:
                    task.status = "error"
                    task.error = f"yt-dlp exited with code {code}"
        except Exception as exc:
            with task.lock:
                task.status = "error"
                task.error = str(exc)


def create_handler(engine: BridgeEngine) -> type[BaseHTTPRequestHandler]:
    class BridgeHandler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: Any) -> None:
            sys.stdout.write(f"[VDownBridge] {self.address_string()} - {format % args}\n")

        def _send_json(self, code: int, payload: dict[str, Any]) -> None:
            raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _read_json(self) -> dict[str, Any]:
            length = int(self.headers.get("Content-Length") or "0")
            body = self.rfile.read(length) if length > 0 else b"{}"
            return dict(json.loads(body.decode("utf-8")))

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            qs = parse_qs(parsed.query)
            if parsed.path == "/health":
                self._send_json(200, {"status": "ok", "output_dir": str(engine.output_dir)})
                return
            if parsed.path == "/api/task/status":
                tid = (qs.get("task_id") or [""])[0]
                self._send_json(200, engine.get_status(tid))
                return
            if parsed.path == "/api/file":
                raw_path = (qs.get("path") or [""])[0]
                target = Path(raw_path)
                if not engine.is_allowed_file(target):
                    self._send_json(403, {"error": "File not found or outside output directory"})
                    return
                mime, _ = mimetypes.guess_type(str(target))
                size = target.stat().st_size
                self.send_response(200)
                self.send_header("Content-Type", mime or "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                with target.open("rb") as fh:
                    while True:
                        chunk = fh.read(262144)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                return
            self._send_json(404, {"error": "Not found"})

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            try:
                body = self._read_json()
                if parsed.path == "/api/info":
                    url = str(body.get("url") or "").strip()
                    if not url:
                        self._send_json(400, {"error": "Missing url"})
                        return
                    self._send_json(200, engine.fetch_info(url))
                    return
                if parsed.path == "/api/task/start":
                    tid = engine.start_task(body)
                    self._send_json(200, {"task_id": tid})
                    return
                if parsed.path == "/api/task/stop":
                    tid = str(body.get("task_id") or "")
                    self._send_json(200, engine.stop_task(tid))
                    return
                if parsed.path == "/api/task/split":
                    tid = str(body.get("task_id") or "")
                    self._send_json(200, engine.split_task(tid))
                    return
                if parsed.path == "/api/task/cancel":
                    tid = str(body.get("task_id") or "")
                    self._send_json(200, engine.cancel_task(tid))
                    return
                self._send_json(404, {"error": "Not found"})
            except Exception as exc:
                self._send_json(500, {"error": str(exc)})

    return BridgeHandler


def main() -> None:
    parser = argparse.ArgumentParser(description="VDown Companion Bridge for HarmonyOS")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8765, help="Bind port (default 8765)")
    parser.add_argument("--output-dir", default="./vdown_bridge_downloads", help="Output directory")
    parser.add_argument("--ytdlp", default="", help="Path to yt-dlp binary")
    parser.add_argument("--ffmpeg", default="", help="Path to ffmpeg binary")
    parser.add_argument("--proxy", default="", help="HTTP/SOCKS proxy URL")
    parser.add_argument("--cookies-from-browser", default="", help="Browser name for yt-dlp cookies")
    args = parser.parse_args()

    local_appdata = os.environ.get("LOCALAPPDATA", "")
    ytdlp_bin = args.ytdlp or _find_binary(
        "yt-dlp",
        [
            str(Path.home() / "AppData/Local/VDown/bin/yt-dlp.exe"),
            f"{local_appdata}/VDown/bin/yt-dlp.exe" if local_appdata else "",
        ],
    )
    ffmpeg_bin = args.ffmpeg or _find_binary(
        "ffmpeg",
        [
            str(Path.home() / "AppData/Local/VDown/bin/ffmpeg.exe"),
            f"{local_appdata}/VDown/bin/ffmpeg.exe" if local_appdata else "",
        ],
    )

    engine = BridgeEngine(
        ytdlp_bin=ytdlp_bin,
        ffmpeg_bin=ffmpeg_bin,
        output_dir=Path(args.output_dir),
        proxy=args.proxy,
        cookies_from_browser=args.cookies_from_browser,
    )
    server = ThreadingHTTPServer((args.host, args.port), create_handler(engine))
    print(f"VDown Companion Bridge listening on http://{args.host}:{args.port}")
    print(f"yt-dlp: {ytdlp_bin}")
    print(f"ffmpeg: {ffmpeg_bin}")
    print(f"output: {engine.output_dir}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down VDown Bridge...")
        server.server_close()


if __name__ == "__main__":
    main()
