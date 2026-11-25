#!/usr/bin/env python3
"""Run a command with a time limit: GNU timeout's interface, wherever Python 3 runs.

WHY THIS EXISTS

A network call with no deadline can hold its caller forever, and
scripts/check-network-deadlines.py holds every call in the scripts, workflows
and Taskfile to a bound. The Taskfile and the shell scripts run on
contributors' Macs as well as on Linux CI, and macOS ships no `timeout`.
Homebrew's coreutils installs it as `gtimeout`. Python 3 is already a
prerequisite of `task check`, so the bound those files use is this script,
with GNU timeout's arguments and exit statuses, rather than one more tool to
install.

USAGE

  deadline.py [OPTION]... DURATION COMMAND [ARG]...
  deadline.py --self-test

Starts COMMAND, and signals it if it is still running after DURATION.

DURATION is a number with an optional suffix: s for seconds (the default), m
for minutes, h for hours, d for days. A duration of 0 sets no deadline.

  -s, --signal=SIGNAL        the signal to send at the deadline, by name (TERM,
                             SIGTERM) or number; TERM by default
  -k, --kill-after=DURATION  also send KILL if COMMAND is still running this
                             long after the first signal
      --preserve-status      exit with COMMAND's status even when the deadline
                             fires
      --foreground           leave COMMAND in this process's group, so it can
                             read from the terminal; its children are then not
                             signalled at the deadline
  -v, --verbose              report each signal sent, on stderr
      --help                 print this text and exit

Options come first, and the first word that is not one is DURATION, so
COMMAND's own options are never read as these. Unless --foreground is given,
COMMAND runs in its own process group, and a signal reaches every process it
started. INT, TERM, HUP and QUIT sent to this script are passed on to COMMAND
the same way.

EXIT STATUS, as GNU timeout's

  124  the deadline fired, and --preserve-status was not given
  125  this script failed: a bad option, duration or signal
  126  COMMAND was found but could not run
  127  COMMAND was not found
  137  COMMAND was killed with KILL at the deadline, by -s KILL or by -k

Otherwise it is COMMAND's own status. A COMMAND that a signal ends before the
deadline ends this script with the same signal, so the caller sees what the
command saw.

`--self-test` runs each behaviour above against short-lived commands, with the
exit status and message each must produce.
"""

from __future__ import annotations

import contextlib
import io
import os
import re
import resource
import signal
import stat
import subprocess
import sys
import tempfile
import time

EXIT_TIMEDOUT = 124
EXIT_CANCELED = 125
EXIT_CANNOT_INVOKE = 126
EXIT_ENOENT = 127

FORWARDED = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT)
UNITS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
DURATION = re.compile(r"(\d+(?:\.\d*)?|\.\d+)([smhd]?)")
LONG = {"signal": "s", "kill-after": "k", "preserve-status": "p", "foreground": "f",
        "verbose": "v", "help": "h"}
SHORT = "skv"
TAKES_VALUE = "sk"


class UsageError(Exception):
    """An argument this script cannot act on: it exits 125."""


class HelpRequested(Exception):
    """--help: print the docstring and exit 0."""


class Options:
    def __init__(self) -> None:
        self.signal = int(signal.SIGTERM)
        self.kill_after = 0.0
        self.preserve_status = False
        self.foreground = False
        self.verbose = False


def duration(text: str) -> float:
    match = DURATION.fullmatch(text)
    if not match:
        raise UsageError(f"invalid time interval '{text}'")
    return float(match.group(1)) * UNITS[match.group(2)]


def signal_number(text: str) -> int:
    if text.isdigit():
        if int(text) in {int(s) for s in signal.valid_signals()}:
            return int(text)
    else:
        name = text.upper()
        name = name if name.startswith("SIG") else "SIG" + name
        if name in signal.Signals.__members__:
            return int(signal.Signals[name])
    raise UsageError(f"{text}: invalid signal")


def signal_name(number: int) -> str:
    return signal.Signals(number).name[3:]


def apply(opts: Options, key: str, value: str | None) -> None:
    if key == "s":
        opts.signal = signal_number(value or "")
    elif key == "k":
        opts.kill_after = duration(value or "")
    elif key == "p":
        opts.preserve_status = True
    elif key == "f":
        opts.foreground = True
    elif key == "v":
        opts.verbose = True
    else:
        raise HelpRequested


def parse(argv: list[str]) -> tuple[Options, float, list[str]]:
    """(options, deadline in seconds, command), read the way GNU timeout reads them."""
    opts = Options()
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            i += 1
            break
        if arg.startswith("--"):
            name, eq, value = arg[2:].partition("=")
            if name not in LONG:
                raise UsageError(f"unrecognized option '--{name}'")
            key = LONG[name]
            if key in TAKES_VALUE:
                if not eq:
                    i += 1
                    if i == len(argv):
                        raise UsageError(f"option '--{name}' requires an argument")
                    value = argv[i]
                apply(opts, key, value)
            elif eq:
                raise UsageError(f"option '--{name}' doesn't allow an argument")
            else:
                apply(opts, key, None)
        elif arg.startswith("-") and arg != "-":
            # Short options cluster, as getopt reads them: `-vk 5` is `-v -k 5`, and
            # an option that takes a value takes the rest of the word, or the next.
            for j in range(1, len(arg)):
                key = arg[j]
                if key not in SHORT:
                    raise UsageError(f"invalid option -- '{key}'")
                if key in TAKES_VALUE:
                    value = arg[j + 1:]
                    if not value:
                        i += 1
                        if i == len(argv):
                            raise UsageError(f"option requires an argument -- '{key}'")
                        value = argv[i]
                    apply(opts, key, value)
                    break
                apply(opts, key, None)
        else:
            break
        i += 1
    operands = argv[i:]
    if len(operands) < 2:
        raise UsageError("missing operand" if not operands
                         else f"missing operand after '{operands[0]}'")
    return opts, duration(operands[0]), operands[1:]


def run(argv: list[str]) -> int:
    try:
        opts, limit, command = parse(argv)
    except HelpRequested:
        print(__doc__)
        return 0
    except UsageError as e:
        print(f"deadline.py: {e}\nTry 'deadline.py --help' for more information.",
              file=sys.stderr)
        return EXIT_CANCELED

    try:
        child = subprocess.Popen(command, preexec_fn=None if opts.foreground else os.setpgrp)
    except FileNotFoundError:
        print(f"deadline.py: failed to run command '{command[0]}': No such file or directory",
              file=sys.stderr)
        return EXIT_ENOENT
    except OSError as e:
        print(f"deadline.py: failed to run command '{command[0]}': {e.strerror}",
              file=sys.stderr)
        return EXIT_CANNOT_INVOKE

    def send(sig: int, report: bool = True) -> None:
        if opts.verbose and report:
            print(f"deadline.py: sending signal {signal_name(sig)} to command '{command[0]}'",
                  file=sys.stderr)
        with contextlib.suppress(ProcessLookupError):
            if opts.foreground:
                os.kill(child.pid, sig)
            else:
                os.killpg(child.pid, sig)

    for sig in FORWARDED:
        signal.signal(sig, lambda signum, frame: send(signum))

    timed_out = False
    try:
        status = child.wait(timeout=limit or None)
    except subprocess.TimeoutExpired:
        timed_out = True
        send(opts.signal)
        # A stopped command cannot act on the signal until it runs again.
        if opts.signal not in (signal.SIGKILL, signal.SIGCONT):
            send(signal.SIGCONT, report=False)
        try:
            status = child.wait(timeout=opts.kill_after or None)
        except subprocess.TimeoutExpired:
            send(signal.SIGKILL)
            status = child.wait()

    for sig in FORWARDED:
        signal.signal(sig, signal.SIG_DFL)
    if status >= 0:
        return EXIT_TIMEDOUT if timed_out and not opts.preserve_status else status
    killed_by = -status
    if timed_out and killed_by != signal.SIGKILL and not opts.preserve_status:
        return EXIT_TIMEDOUT
    if not timed_out:
        # End the way the command ended. With core dumps off, so that a command
        # that dumped core leaves one core file, not two.
        with contextlib.suppress(ValueError, OSError):
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            signal.signal(killed_by, signal.SIG_DFL)
            os.kill(os.getpid(), killed_by)
    return 128 + killed_by


# --- self-test --------------------------------------------------------------

SLEEP = "import time; time.sleep(30)"
IGNORE_TERM = "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"
# Starts a grandchild that sleeps, writes its pid where the case says, then sleeps.
# The grandchild's standard streams are /dev/null: holding the case's output pipe,
# it would keep the case waiting for end-of-file however early deadline.py exited.
SPAWN = ("import subprocess, sys, time; p = subprocess.Popen([sys.executable, '-c', "
         "'import time; time.sleep(30)'], stdin=subprocess.DEVNULL, "
         "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
         "open(sys.argv[1], 'w').write(str(p.pid)); time.sleep(30)")
FAST = 15.0  # seconds; a case that should end at its deadline ends well inside this


def py(code: str, *args: str) -> list[str]:
    return [sys.executable, "-c", code, *args]


def cases(tmp: str) -> list[tuple[str, list[str], int, str]]:
    """(name, arguments, expected status, text stdout or stderr must hold)."""
    noexec = os.path.join(tmp, "not-executable")
    with open(noexec, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(noexec, stat.S_IRUSR | stat.S_IWUSR)
    return [
        ("a command that finishes in time exits with its own status",
         ["5", *py("raise SystemExit(3)")], 3, ""),
        ("a command that succeeds in time exits 0", ["5", *py("pass")], 0, ""),
        ("the deadline fires: 124", ["0.3", *py(SLEEP)], 124, ""),
        ("a duration takes a unit", ["0.005m", *py(SLEEP)], 124, ""),
        ("0 sets no deadline", ["0", *py("import time; time.sleep(0.5)")], 0, ""),
        ("--preserve-status at the deadline: TERM's 143",
         ["--preserve-status", "0.3", *py(SLEEP)], 128 + signal.SIGTERM, ""),
        ("-k sends KILL to a command that ignores TERM: 137",
         ["-k", "0.3", "0.3", *py(IGNORE_TERM)], 137, ""),
        ("--kill-after= in its long form", ["--kill-after=0.3", "0.3", *py(IGNORE_TERM)], 137,
         ""),
        ("short options cluster: -vk", ["-vk", "0.3", "0.3", *py(IGNORE_TERM)], 137,
         "sending signal KILL"),
        ("-s KILL at the deadline: 137", ["-s", "KILL", "0.3", *py(SLEEP)], 137, ""),
        ("-s takes a SIG name", ["-s", "SIGINT", "0.3", *py(SLEEP)], 124, ""),
        ("-s takes a number", ["-s", str(int(signal.SIGHUP)), "0.3", *py(SLEEP)], 124, ""),
        ("-s takes its value in the same word", ["-sINT", "0.3", *py(SLEEP)], 124, ""),
        ("--signal= in its long form", ["--signal=TERM", "0.3", *py(SLEEP)], 124, ""),
        ("--verbose reports the signal", ["--verbose", "0.3", *py(SLEEP)], 124,
         "sending signal TERM to command"),
        ("--foreground still keeps the deadline", ["--foreground", "0.3", *py(SLEEP)], 124, ""),
        ("options stop at DURATION, so COMMAND keeps its own",
         ["5", *py("import sys; print(sys.argv[1:])", "-v")], 0, "['-v']"),
        ("-- ends the options", ["--", "5", *py("pass")], 0, ""),
        ("a command that is not found: 127", ["5", os.path.join(tmp, "no-such-command")], 127,
         "No such file or directory"),
        ("a command that cannot run: 126", ["5", noexec], 126, "failed to run command"),
        ("a bad duration: 125", ["soon", "true"], 125, "invalid time interval 'soon'"),
        ("a negative duration reads as an option: 125", ["-5", "true"], 125,
         "invalid option -- '5'"),
        ("a bad -k duration: 125", ["-k", "later", "1", "true"], 125, "invalid time interval"),
        ("a bad signal name: 125", ["-s", "NOPE", "1", "true"], 125, "NOPE: invalid signal"),
        ("a bad signal number: 125", ["-s", "999", "1", "true"], 125, "999: invalid signal"),
        ("an unknown long option: 125", ["--bogus", "1", "true"], 125,
         "unrecognized option '--bogus'"),
        ("an unknown short option: 125", ["-x", "1", "true"], 125, "invalid option -- 'x'"),
        ("a long option missing its value: 125", ["--signal"], 125,
         "option '--signal' requires an argument"),
        ("a short option missing its value: 125", ["-k"], 125,
         "option requires an argument -- 'k'"),
        ("a flag given a value: 125", ["--verbose=yes", "1", "true"], 125,
         "doesn't allow an argument"),
        ("no operand: 125", [], 125, "missing operand"),
        ("a duration and no command: 125", ["5"], 125, "missing operand after '5'"),
        ("--help prints the usage", ["--help"], 0, "EXIT STATUS"),
    ]


def outcome(args: list[str]) -> tuple[int, str, float]:
    start = time.monotonic()
    proc = subprocess.run([sys.executable, os.path.abspath(__file__), *args],
                          capture_output=True, text=True, timeout=60, check=False)
    return proc.returncode, proc.stdout + proc.stderr, time.monotonic() - start


def alive(pid: int) -> bool:
    """Whether pid is a running process. A zombie has ended, whether or not its new
    parent has reaped it yet, which in a container may be never."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True,
                           text=True, timeout=10, check=False).stdout.strip()
    return bool(state) and not state.startswith("Z")


def gone_within(pid: int, seconds: float) -> bool:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if not alive(pid):
            return True
        time.sleep(0.05)
    return False


def group_outcome(tmp: str, foreground: bool) -> tuple[int, bool]:
    """(status, whether the grandchild outlived the deadline) for a command with a child."""
    pidfile = os.path.join(tmp, f"grandchild-{foreground}")
    status, _, _ = outcome([*(["--foreground"] if foreground else []), "1",
                            *py(SPAWN, pidfile)])
    with open(pidfile) as f:
        pid = int(f.read())
    survived = not gone_within(pid, 3)
    if survived:
        os.kill(pid, signal.SIGKILL)
    return status, survived


def signalled_outcome() -> tuple[int, float]:
    """(status, seconds) of deadline.py sent TERM while its command runs."""
    start = time.monotonic()
    proc = subprocess.Popen([sys.executable, os.path.abspath(__file__), "30", *py(SLEEP)])
    time.sleep(1)
    proc.send_signal(signal.SIGTERM)
    return proc.wait(timeout=30), time.monotonic() - start


def self_test(planted: list[tuple[str, list[str], int, str]] | None = None,
              meta: bool = True) -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="deadline-self-test-") as tmp:
        planted = planted if planted is not None else cases(tmp)
        for name, args, want, says in planted:
            status, output, seconds = outcome(args)
            if status != want or says not in output or seconds > FAST:
                failures.append(f"{name}: exit {status} in {seconds:.1f}s, wanted {want} "
                                f"with \"{says}\"\n" + "".join(
                                    f"      {line}\n" for line in output.splitlines()[-4:]))
        if meta:
            status, survived = group_outcome(tmp, foreground=False)
            if status != EXIT_TIMEDOUT or survived:
                failures.append(f"the deadline reaches the command's children: exit {status}, "
                                f"grandchild {'survived' if survived else 'gone'}")
            status, survived = group_outcome(tmp, foreground=True)
            if status != EXIT_TIMEDOUT or not survived:
                failures.append(f"--foreground signals the command alone: exit {status}, "
                                f"grandchild {'survived' if survived else 'gone'}")
            status, seconds = signalled_outcome()
            if status != -signal.SIGTERM or seconds > FAST:
                failures.append(f"TERM sent to deadline.py reaches its command, and ends "
                                f"deadline.py with it: exit {status} in {seconds:.1f}s")
            status, output, _ = outcome(["5", *py("import os, signal; "
                                                 "os.kill(os.getpid(), signal.SIGTERM)")])
            if status != -signal.SIGTERM:
                failures.append(f"a command a signal ends before the deadline ends deadline.py "
                                f"with that signal: exit {status}")
            wrong = [("a case whose expectation is wrong", ["5", *py("pass")], 1, "")]
            with contextlib.redirect_stdout(io.StringIO()):
                if self_test(wrong, meta=False) != 1:
                    failures.append("a self-test over a case that fails must fail")
    if failures:
        print("deadline.py --self-test FAILED:")
        for failure in failures:
            print("  - " + failure)
        return 1
    if meta:
        print(f"deadline.py --self-test: {len(planted)} case(s) and 5 behaviour check(s) "
              f"pass.")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(run(sys.argv[1:]))
