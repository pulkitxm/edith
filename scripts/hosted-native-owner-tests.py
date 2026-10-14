from pathlib import Path
import ctypes
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


spec = importlib.util.spec_from_file_location(
    'hosted_process_watchdog', Path(__file__).parent / 'hosted-host-tests/watchdog.py')
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)

TARGETS = {
    'attention': ['ci-extension-attention'],
    'terminal': ['ci-extension-terminal'],
    'timeLapse': ['ci-extension-time-lapse'],
    'studio': ['ci-extension-studio', 'ci-extension-studio-native'],
    'machines': ['ci-extension-machines'],
    'virtualCamera': [
        'ci-extension-camera', 'ci-extension-camera-carrier', 'ci-extension-camera-voice'],
    'feature-models': ['ci-extension-support', 'ci-extension-docs'],
    'database-mutation': ['ci-extension-database-mutation'],
    'database-executor': ['ci-extension-database-executor'],
}
DATABASE_DIAGNOSTICS = {'database-mutation', 'database-executor'}
TEST_DEADLINE = 2400
LOG_BOUND = 16_777_216


class BoundedOwnership(watchdog.OwnedProcesses):
    def __init__(self, leader, uid):
        super().__init__(leader, uid)
        self.errors = []
        self.seals = {}
        self.transitions = []
        self.terminal_children = {}
        self.exiting_processes = {}
        self.joined_cleanup = False
        self.snapshot_pid = None
        self.snapshot_exit_record = None
        self.terminal_child_refusals = {}
        self.rejected = {}
        self.failure_observations = []
        self.failure_observation_keys = set()
        self.captured_snapshot_failures = []
        self.captured_snapshot_keys = set()
        self.admission_parents = {}
        self.child_self_groups = {}
        self.child_group_transitions = {}
        self.self_group_observations = {}
        self.pending_children = {}
        self.pending_failures = set()
        self.recovery_failure_stages = {}
        self.last_recovery_failure = None
        self.private_failure_pid_roles = {}
        value = self.snapshot(leader)
        if value is None or value[4] != leader:
            raise RuntimeError('Owned leader identity unavailable')
        identity = value[:5]
        self.seals[leader] = identity[:3] + identity[4:5]
        self.known[leader] = identity

    def snapshot(self, pid, parent=None, parent_identity=None):
        self.last_recovery_failure = None
        self.snapshot_pid = pid
        self.snapshot_exit_record = None
        self.terminal_child_refusals.pop(pid, None)
        self.recovery_failure_stages.pop(pid, None)
        if pid in self.pending_failures:
            raise RuntimeError('Pending owned child identity permanently rejected')
        captured = None
        original_record = None

        def retain_record(result, info):
            nonlocal original_record
            original_record = (result, info, False)
            self.retain_exit_record(pid, result, info)

        def capture(clause, result, info):
            nonlocal captured
            complete = result == ctypes.sizeof(info)
            seal = self.seals.get(pid)
            captured = {
                'clause': clause,
                'returnedBytes': result if type(result) is int and -2147483648 <= result <= 2147483647 else None,
                'expectedBytes': ctypes.sizeof(info),
                'status': info.status if complete else None,
                'pidMatches': info.pid == pid if complete else None,
                'birthMatches': (pid, info.seconds, info.microseconds) == seal[:3] if complete and seal else None,
                'groupMatches': info.pgid == seal[3] if complete and seal else None,
                'uidMatches': info.uid == self.uid if complete else None,
                'realUIDMatches': info.ruid == self.uid if complete else None,
                'parentEnumerated': parent is not None,
                'parentIdentityKnown': parent_identity is not None,
                'parentMatches': info.ppid == parent if complete and parent is not None else None,
                'leaderGroupMatches': info.pgid == self.leader if complete else None,
            }

        value = super().snapshot(pid, capture, retain_record)
        if pid in self.exiting_processes:
            if self.exiting_process_absent(pid):
                if self.joined_cleanup:
                    self.exiting_processes.pop(pid)
                return None
            record = original_record if original_record[0] == ctypes.sizeof(original_record[1]) else self.diagnostic_record(pid)
            if self.record_exiting_process(pid, parent, parent_identity, record):
                return None
            self.observe_failure(pid, 'live_identity_unavailable', record=record)
            raise RuntimeError('Terminal process identity could not be authenticated')
        if (type(original_record[0]) is int and original_record[0] == ctypes.sizeof(original_record[1])
                and original_record[1].flags & 4):
            if self.record_exiting_process(pid, parent, parent_identity, original_record):
                return None
            self.observe_failure(pid, 'live_identity_unavailable', record=original_record)
            raise RuntimeError('Live owned process identity unavailable')
        if value is None:
            if captured is not None and captured['clause'] == 'kernel_record_unavailable':
                if self.terminal_child(pid, parent, parent_identity):
                    self.terminal_child_refusals.pop(pid, None)
                    return None
                alternate = (type(captured['returnedBytes']) is int and captured['returnedBytes'] == 0
                             and type(pid) is int and pid > 0 and pid != self.leader
                             and pid in self.known and pid in self.seals and pid not in self.rejected)
                recovered = self.recover_snapshot(pid, include_zombies=alternate)
                if recovered is not None:
                    self.terminal_child_refusals.pop(pid, None)
                    return recovered
                if captured['returnedBytes'] == 0:
                    recovered = self.recover_unsealed_child(pid, parent, parent_identity)
                    if recovered is not None:
                        self.terminal_child_refusals.pop(pid, None)
                        return recovered
                if captured['returnedBytes'] == 0 and self.defer_kernel_child(pid, parent, parent_identity):
                    self.terminal_child_refusals.pop(pid, None)
                    return None
            if self.sealed_zombie(pid):
                self.terminal_child_refusals.pop(pid, None)
                return None
            record = self.snapshot_exit_record
            if record is None:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    self.terminal_child_refusals.pop(pid, None)
                    return None
                record = self.diagnostic_record(pid)
            eligible = (captured is not None and (
                captured['clause'] == 'kernel_record_unavailable' and captured['returnedBytes'] == 0
                or captured['clause'] == 'executable_path_unavailable'
                and captured['pidMatches'] and captured['uidMatches'] and captured['realUIDMatches']))
            if eligible and self.record_exiting_process(pid, parent, parent_identity, record):
                self.terminal_child_refusals.pop(pid, None)
                return None
            self.observe_failure(pid, 'live_identity_unavailable', record=record)
            if (captured is not None and pid not in self.captured_snapshot_keys
                    and len(self.captured_snapshot_failures) < 8):
                self.captured_snapshot_keys.add(pid)
                self.captured_snapshot_failures.append(captured)
            raise RuntimeError('Live owned process identity unavailable')
        if pid in self.terminal_children:
            raise RuntimeError('Terminal child identity became live')
        if pid in self.pending_children:
            value = self.resolve_pending_child(pid, value)
        self.terminal_child_refusals.pop(pid, None)
        return value

    def retain_exit_record(self, pid, result, info):
        if (pid == self.snapshot_pid and type(result) is int
                and result == ctypes.sizeof(info) and info.flags & 4):
            self.snapshot_exit_record = (result, watchdog.ProcessInfo.from_buffer_copy(bytes(info)), False)

    def complete_terminal_record(self, pid, record):
        result, info, failed = record
        if (failed or type(result) is not int or result != ctypes.sizeof(info)
                or info.pid != pid or info.status not in (1, 2, 3, 4, 5)
                or info.uid != self.uid or info.ruid != self.uid
                or info.seconds <= 0 or info.microseconds >= 1_000_000
                or info.pgid <= 0 or info.ppid <= 0 or not info.flags & 4):
            return None
        return bytes(info), (pid, info.seconds, info.microseconds, '',
                             info.pgid, info.ppid, info.uid, info.ruid)

    def retained_parent_record(self, parent, identity):
        result, info, failed = self.diagnostic_record(parent)
        if (failed or type(result) is not int or result != ctypes.sizeof(info)
                or info.pid != parent or info.status not in (1, 2, 3, 4, 5)
                or info.uid != self.uid or info.ruid != self.uid
                or info.seconds <= 0 or info.microseconds >= 1_000_000
                or info.pgid <= 0 or info.ppid <= 0 or info.status == 5 and not info.flags & 4
                or (parent, info.seconds, info.microseconds, info.pgid) != self.current_seal(parent)
                or identity[:3] + identity[4:5] != self.current_seal(parent)):
            return None
        if not info.flags & 4:
            path = ctypes.create_string_buffer(4096)
            if (self.library.proc_pidpath(parent, path, len(path)) <= 0
                    or path.value != identity[3].encode()):
                return None
        return bytes(info)

    def record_exiting_process(self, pid, parent, parent_identity, sample):
        if type(pid) is not int or pid <= 0 or pid in self.rejected:
            return False
        candidate = self.complete_terminal_record(pid, sample)
        if candidate is None:
            return False
        retained = self.exiting_processes.get(pid)
        seal = self.current_seal(pid)
        before = None
        if retained is not None:
            if candidate[1][:3] + candidate[1][4:5] != retained[:3] + retained[4:5]:
                return False
        elif seal is not None:
            if candidate[1][:3] + candidate[1][4:5] != seal:
                return False
        else:
            if (pid == self.leader or type(parent) is not int or parent <= 0
                    or parent in self.rejected or parent_identity is None
                    or parent_identity != self.known.get(parent)
                    and parent_identity != self.exiting_processes.get(parent, ())[:5]
                    or parent_identity[:3] + parent_identity[4:5] != self.current_seal(parent)
                    or candidate[1][5] != parent or candidate[1][4] not in (parent_identity[4], pid)):
                return False
            before = self.retained_parent_record(parent, parent_identity)
            if before is None:
                return False
        first = self.complete_terminal_record(pid, self.diagnostic_record(pid))
        second = self.complete_terminal_record(pid, self.diagnostic_record(pid))
        if first is None or first != second or first[1] != candidate[1]:
            return False
        if before is not None and self.retained_parent_record(parent, parent_identity) != before:
            return False
        if retained is None:
            if pid not in self.seals and self.lifetime_count() - (pid in self.pending_children) >= 4096:
                raise RuntimeError('Owned lifetime process bound exceeded')
            if len(self.known) + len(self.pending_children) + len(self.exiting_processes) - (pid in self.known) >= 64:
                raise RuntimeError('Owned concurrent descendant bound exceeded')
            identity = self.known.get(pid)
            terminal = first[1][:3] + ((identity[3] if identity else ''),) + first[1][4:]
            self.exiting_processes[pid] = terminal
            self.terminal_children[pid] = first[0]
            self.pending_children.pop(pid, None)
        return True

    def exiting_process_absent(self, pid):
        for _ in range(2):
            for argument in (0, 1):
                info = watchdog.ProcessInfo()
                result = self.library.proc_pidinfo(pid, 3, argument, ctypes.byref(info), ctypes.sizeof(info))
                self.retain_exit_record(pid, result, info)
                if type(result) is not int or result != 0:
                    return False
            path = ctypes.create_string_buffer(4096)
            if self.library.proc_pidpath(pid, path, len(path)) != 0:
                return False
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            return False
        return True

    def begin_joined_cleanup(self, reaped):
        self.joined_cleanup = reaped

    def finalize_exiting_processes(self, reaped):
        for pid in list(self.exiting_processes):
            try:
                absent = reaped and self.exiting_process_absent(pid)
            except OSError:
                absent = False
            if absent:
                self.exiting_processes.pop(pid)
            else:
                self.reject(pid, 'Terminal owned process unresolved after join')

    def recover_unsealed_child(self, pid, parent, parent_identity):
        if (type(pid) is not int or pid <= 0 or pid == self.leader
                or pid in self.known or pid in self.seals or pid in self.terminal_children
                or pid in self.pending_children or pid in self.rejected
                or type(parent) is not int or parent <= 0 or parent in self.rejected
                or parent_identity is None or parent_identity != self.known.get(parent)
                or parent_identity[:3] + parent_identity[4:5] != self.current_seal(parent)):
            return None
        before = self.complete_live_record(parent)
        if before is None or before[1][:5] != parent_identity:
            return None
        children = [self.complete_live_record(pid, 1), self.complete_live_record(pid, 1)]
        if any(child is None for child in children) or children[0] != children[1]:
            return None
        child = children[0][1]
        if not child[3] or child[5] != parent or child[4] not in (before[1][4], pid):
            return None
        after = self.complete_live_record(parent)
        if after is None or before != after:
            return None
        return child[:6]

    def defer_kernel_child(self, pid, parent, parent_identity):
        if (type(pid) is not int or pid <= 0 or pid == self.leader
                or pid in self.seals or pid in self.known or pid in self.terminal_children
                or pid in self.rejected or type(parent) is not int or parent <= 0
                or parent in self.rejected):
            return False
        retained = self.pending_children.get(pid)
        if (parent_identity is None and (retained is None or retained[0] != parent)):
            return False
        if parent_identity is not None and parent_identity != self.known.get(parent):
            return False
        for _ in range(2):
            info = watchdog.ProcessInfo()
            result = self.library.proc_pidinfo(pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info))
            self.retain_exit_record(pid, result, info)
            if type(result) is not int or result != 0:
                return False
        if retained is not None and parent_identity is None:
            return True
        before = self.complete_live_record(parent)
        after = self.complete_live_record(parent)
        if (before is None or before != after or before[1][:5] != parent_identity
                or before[1][:3] + before[1][4:5] != self.current_seal(parent)):
            return False
        if retained is not None and retained != before[1]:
            raise RuntimeError('Pending child parent identity changed')
        if retained is None:
            if self.lifetime_count() >= 4096:
                raise RuntimeError('Owned lifetime process bound exceeded')
            if len(self.known) + len(self.pending_children) + len(self.exiting_processes) >= 64:
                raise RuntimeError('Owned concurrent descendant bound exceeded')
            self.pending_children[pid] = before[1]
        return True

    def resolve_pending_child(self, pid, current):
        parent = self.pending_children[pid]
        before = self.complete_live_record(parent[0])
        children = [self.complete_live_record(pid), self.complete_live_record(pid)]
        after = self.complete_live_record(parent[0])
        if (before is None or before != after or before[1] != parent
                or before[1][:3] + before[1][4:5] != self.current_seal(parent[0])
                or any(child is None for child in children) or children[0] != children[1]
                or children[0][1][:6] != current or current[5] != parent[0]
                or current[4] != parent[4]):
            raise RuntimeError('Pending child identity could not be authenticated')
        return current

    def pending_child_absent(self, pid):
        for _ in range(2):
            info = watchdog.ProcessInfo()
            result = self.library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
            self.retain_exit_record(pid, result, info)
            if type(result) is not int or result != 0:
                return False
            path = ctypes.create_string_buffer(4096)
            if self.library.proc_pidpath(pid, path, len(path)) != 0:
                return False
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            return False
        return True

    def finalize_pending_children(self, reaped):
        for pid in list(self.pending_children):
            try:
                absent = reaped and self.pending_child_absent(pid)
            except OSError:
                absent = False
            if absent:
                self.pending_children.pop(pid)
            else:
                self.pending_failures.add(pid)
                self.reject(pid, 'Pending owned child identity unresolved after join')

    def terminal_child(self, pid, parent, parent_identity):
        if (type(pid) is not int or pid <= 0 or type(parent) is not int or parent <= 0
                or pid == self.leader or pid in self.seals or pid in self.known
                or parent is None or parent_identity is None
                or parent_identity != self.known.get(parent)
                or parent_identity[0] != parent or parent_identity[4] != self.leader):
            return self.terminal_child_refusal(pid, parent, parent_identity, 'parent_admission')
        before_parent = self.recover_snapshot(parent)
        if before_parent is None or before_parent[:5] != parent_identity:
            return self.terminal_child_refusal(pid, parent, parent_identity, 'parent_before')
        records = []
        for _ in range(2):
            info = watchdog.ProcessInfo()
            result = self.library.proc_pidinfo(pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info))
            self.retain_exit_record(pid, result, info)
            if (type(result) is not int or result != ctypes.sizeof(info)
                    or info.status != 5 or info.flags & 4 or info.pid != pid
                    or info.uid != self.uid or info.ruid != self.uid
                    or info.ppid != parent or info.pgid != self.leader
                    or info.seconds <= 0 or info.microseconds >= 1_000_000):
                return self.terminal_child_refusal(
                    pid, parent, parent_identity,
                    'first_child_record' if not records else 'second_child_record', info, result)
            records.append(bytes(info))
        after_parent = self.recover_snapshot(parent)
        if (records[0] != records[1] or after_parent is None
                or after_parent[:5] != parent_identity):
            return self.terminal_child_refusal(
                pid, parent, parent_identity,
                'child_records_changed' if records[0] != records[1] else 'parent_after',
                info, result, records[0] == records[1])
        previous = self.terminal_children.get(pid)
        if previous is not None and previous != records[0]:
            raise RuntimeError('Terminal child kernel record changed')
        if previous is None and self.lifetime_count() - (pid in self.pending_children) >= 4096:
            raise RuntimeError('Owned lifetime process bound exceeded')
        self.terminal_children[pid] = records[0]
        return True

    def terminal_child_refusal(self, pid, parent, parent_identity, reason,
                               info=None, result=None, stable=None):
        if (type(pid) is int and pid > 0 and pid not in self.terminal_child_refusals
                and len(self.terminal_child_refusals) < 8):
            identity = parent_identity if type(parent_identity) is tuple and len(parent_identity) == 5 else None
            complete = info is not None and type(result) is int and result == ctypes.sizeof(info)
            self.terminal_child_refusals[pid] = {
                'terminalRefusalReason': reason if type(reason) is str and reason in {
                    'parent_admission', 'parent_before', 'first_child_record',
                    'second_child_record', 'child_records_changed', 'parent_after',
                } else 'unknown',
                'terminalChildRole': 'leader' if pid == self.leader else 'known' if pid in self.known else 'unsealed',
                'terminalParentIdentityKnown': identity is not None and identity == self.known.get(parent),
                'terminalParentPIDMatches': identity[0] == parent if identity is not None else None,
                'terminalParentGroupMatchesLeader': identity[4] == self.leader if identity is not None else None,
                'terminalParentGroupMatchesSeal': identity[:3] + identity[4:5] == self.current_seal(parent)
                if identity is not None else None,
                'terminalParentGroupIsSelf': identity[4] == identity[0] if identity is not None else None,
                'terminalChildRecordComplete': complete if info is not None else None,
                'terminalChildIsZombie': info.status == 5 if complete else None,
                'terminalChildGroupIsSelf': info.pgid == pid if complete else None,
                'terminalChildGroupMatchesParent': info.pgid == identity[4] if complete and identity is not None else None,
                'terminalChildGroupMatchesLeader': info.pgid == self.leader if complete else None,
                'terminalChildParentMatches': info.ppid == parent if complete else None,
                'terminalRawRecordsStable': stable if type(stable) is bool else None,
            }
        return False

    def current_seal(self, pid):
        original = self.seals.get(pid)
        return None if original is None else original[:3] + (self.child_self_groups.get(pid, original[3]),)

    def lifetime_count(self):
        return len(self.seals.keys() | self.terminal_children.keys() | self.pending_children.keys())

    def complete_live_record(self, pid, argument=0):
        info = watchdog.ProcessInfo()
        result = self.library.proc_pidinfo(pid, 3, argument, ctypes.byref(info), ctypes.sizeof(info))
        self.retain_exit_record(pid, result, info)
        if (type(result) is not int or result != ctypes.sizeof(info)
                or info.pid != pid or info.status not in (1, 2, 3, 4) or info.flags & 4
                or info.uid != self.uid or info.ruid != self.uid
                or info.seconds <= 0 or info.microseconds >= 1_000_000
                or info.pgid <= 0 or info.ppid <= 0):
            return None
        path = ctypes.create_string_buffer(4096)
        if self.library.proc_pidpath(pid, path, len(path)) <= 0:
            return None
        try:
            executable = path.value.decode()
        except UnicodeError:
            return None
        identity = (pid, info.seconds, info.microseconds, executable,
                    info.pgid, info.ppid, info.uid, info.ruid)
        return bytes(info), identity

    def admit_child_self_group(self, pid, current):
        previous = self.known.get(pid)
        original = self.seals.get(pid)
        parent = self.admission_parents.get(pid)
        row = {
            'knownChild': previous is not None and original is not None and pid != self.leader,
            'groupIsOwnPID': current[4] == pid,
            'originalParentRetained': parent is not None,
            'currentPathMatchesRetained': previous is not None and current[3] == previous[3],
            'twoChildRecordsMatch': False,
            'parentBeforeMatches': False,
            'parentAfterMatches': False,
            'parentRecordsStable': False,
            'transitionAdmitted': False,
        }
        if pid in self.self_group_observations or len(self.self_group_observations) < 8:
            self.self_group_observations[pid] = row
        if (not row['knownChild'] or not row['groupIsOwnPID'] or parent is None
                or not row['currentPathMatchesRetained'] or current[:3] != original[:3]
                or previous[:3] + previous[4:5] != original
                or pid in self.child_self_groups or pid in self.rejected
                or current[4] == original[3]):
            return False
        parent_before = self.complete_live_record(parent[0])
        row['parentBeforeMatches'] = parent_before is not None and parent_before[1] == parent
        if not row['parentBeforeMatches']:
            return False
        children = [self.complete_live_record(pid), self.complete_live_record(pid)]
        row['twoChildRecordsMatch'] = all(item is not None for item in children) and children[0] == children[1]
        if not row['twoChildRecordsMatch']:
            return False
        child = children[0][1]
        if (child[:3] != original[:3] or child[3] != previous[3] or child[4] != pid
                or child[5] != parent[0] or child[:5] != current):
            return False
        parent_after = self.complete_live_record(parent[0])
        row['parentAfterMatches'] = parent_after is not None and parent_after[1] == parent
        row['parentRecordsStable'] = parent_before == parent_after
        if not row['parentAfterMatches'] or not row['parentRecordsStable']:
            return False
        self.child_self_groups[pid] = pid
        self.child_group_transitions[pid] = (previous, current, parent)
        row['transitionAdmitted'] = True
        return True

    def recover_snapshot(self, pid, include_zombies=False):
        self.last_recovery_failure = None
        self.recovery_failure_stages.pop(pid, None)
        identity = self.known.get(pid)
        seal = self.current_seal(pid)
        if identity is None or seal is None or identity[:3] + identity[4:5] != seal:
            return self.record_recovery_failure(pid, 'retained_identity')
        if include_zombies and (type(pid) is not int or pid <= 0
                                or pid == self.leader or pid in self.rejected):
            return self.record_recovery_failure(pid, 'retained_identity')
        snapshots = []
        for _ in range(2):
            info = watchdog.ProcessInfo()
            result = self.library.proc_pidinfo(
                pid, 3, 1 if include_zombies else 0, ctypes.byref(info), ctypes.sizeof(info))
            self.retain_exit_record(pid, result, info)
            if (type(result) is not int or result != ctypes.sizeof(info)
                    or info.pid != pid or info.status not in (1, 2, 3, 4) or info.flags & 4
                    or info.uid != self.uid or info.ruid != self.uid
                    or info.seconds <= 0 or info.microseconds >= 1_000_000
                    or (pid, info.seconds, info.microseconds, info.pgid) != seal):
                return self.record_recovery_failure(
                    pid, 'first_kernel' if not snapshots else 'second_kernel')
            path = ctypes.create_string_buffer(4096)
            if self.library.proc_pidpath(pid, path, len(path)) <= 0:
                return self.record_recovery_failure(
                    pid, 'first_path' if not snapshots else 'second_path')
            snapshots.append((pid, info.seconds, info.microseconds, path.value.decode(),
                              info.pgid, info.ppid))
        return snapshots[1] if snapshots[0] == snapshots[1] else self.record_recovery_failure(pid, 'snapshot_fields')

    def record_recovery_failure(self, pid, stage):
        self.last_recovery_failure = (pid, stage)
        if (pid in self.known and pid in self.seals
                and (pid in self.recovery_failure_stages or len(self.recovery_failure_stages) < 8)):
            self.recovery_failure_stages[pid] = stage
        return None

    def sealed_zombie(self, pid):
        identity = self.known.get(pid)
        seal = self.current_seal(pid)
        if seal is None or (identity is not None and identity[:3] + identity[4:5] != seal):
            return False
        try:
            info = watchdog.ProcessInfo()
            result = self.library.proc_pidinfo(pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info))
            self.retain_exit_record(pid, result, info)
        except OSError:
            return False
        return (type(result) is int and result == ctypes.sizeof(info)
                and info.status == 5 and not info.flags & 4 and info.pid == pid
                and info.uid == self.uid and info.ruid == self.uid
                and (pid, info.seconds, info.microseconds, info.pgid) == seal)

    def diagnostic_record(self, pid):
        info = watchdog.ProcessInfo()
        try:
            result = self.library.proc_pidinfo(pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info))
            self.retain_exit_record(pid, result, info)
            if type(result) is not int or not -2147483648 <= result <= 2147483647:
                raise ValueError('Invalid diagnostic byte count')
            return result, info, False
        except Exception:
            return None, info, True

    def observe_failure(self, pid, kind, current=None, record=None):
        key = (pid, kind)
        if len(self.failure_observations) >= 8 or key in self.failure_observation_keys:
            return
        self.failure_observation_keys.add(key)
        seal = self.seals.get(pid)
        known = (pid in self.known or pid in self.exiting_processes) and seal is not None
        row = {
            'kind': kind, 'knownSeal': known,
            'originalBirthMatches': current[:3] == seal[:3] if current and known else None,
            'originalGroupMatches': current[4] == seal[3] if current and known else None,
            'returnedBytes': None, 'expectedBytes': ctypes.sizeof(watchdog.ProcessInfo),
            'status': None, 'pidMatches': None, 'birthMatches': None,
            'groupMatches': None, 'uidMatches': None, 'realUIDMatches': None,
            'probeFailed': False, 'processInExit': None,
        }
        result, info, failed = self.diagnostic_record(pid) if record is None else record
        row['probeFailed'] = failed
        if not failed:
            row['returnedBytes'] = result
            if result == ctypes.sizeof(info):
                row.update(status=info.status, pidMatches=info.pid == pid,
                           birthMatches=(pid, info.seconds, info.microseconds) == seal[:3] if known else None,
                           groupMatches=info.pgid == seal[3] if known else None,
                           uidMatches=info.uid == self.uid, realUIDMatches=info.ruid == self.uid,
                           processInExit=bool(info.flags & 4))
        if kind == 'birth_or_group_changed' and pid in self.self_group_observations:
            row.update(self.self_group_observations[pid])
        if kind == 'live_identity_unavailable' and pid in self.recovery_failure_stages:
            row['recoveryFailureStage'] = self.recovery_failure_stages[pid]
        if kind == 'live_identity_unavailable':
            stage = self.last_recovery_failure[1] if (self.last_recovery_failure is not None
                    and self.last_recovery_failure[0] == pid) else 'not_attempted'
            row['recoveryProofStage'] = stage if type(stage) is str and stage in {
                'retained_identity', 'first_kernel', 'second_kernel',
                'first_path', 'second_path', 'snapshot_fields', 'not_attempted',
            } else 'unknown'
        if (type(pid) is int and pid > 0 and pid not in self.private_failure_pid_roles
                and len(self.private_failure_pid_roles) < 8):
            self.private_failure_pid_roles[pid] = (
                'leader' if pid == self.leader else 'known' if known else 'unsealed')
        if kind == 'live_identity_unavailable':
            row.update(self.terminal_child_refusals.get(pid, {}))
        self.failure_observations.append(row)

    def reject(self, pid, message):
        if message not in self.errors and len(self.errors) < 64:
            self.errors.append(message)
        if pid in self.known:
            self.rejected[pid] = self.known[pid]

    def refresh(self):
        pending = [(pid, parent[0]) for pid, parent in self.pending_children.items()]
        pending += [(self.leader, None)] + [(pid, None) for pid in self.known]
        pending += [(pid, None) for pid in self.exiting_processes]
        visited = set()
        active = {}
        while pending:
            pid, parent = pending.pop()
            if pid in visited:
                continue
            visited.add(pid)
            try:
                value = self.snapshot(pid, parent, active.get(parent) or self.exiting_processes.get(parent, ())[:5] or None)
                if value is None:
                    self.known.pop(pid, None)
                    if pid in self.exiting_processes and not self.exiting_process_absent(pid):
                        children = (ctypes.c_int * 64)()
                        count = self.library.proc_listchildpids(pid, children, ctypes.sizeof(children))
                        if count < 0 or count >= len(children):
                            raise RuntimeError('Invalid owned child enumeration')
                        pending.extend((children[index], pid) for index in range(count))
                    continue
                identity = value[:5]
                seal = identity[:3] + identity[4:5]
                previous = self.current_seal(pid)
                if previous is not None and previous != seal:
                    if not self.admit_child_self_group(pid, identity):
                        self.observe_failure(pid, 'birth_or_group_changed', identity)
                        raise RuntimeError('Owned process birth or group changed')
                if previous is None:
                    if pid == self.leader:
                        if identity[4] != self.leader:
                            raise RuntimeError('Owned leader group changed')
                    elif parent not in active or value[5] != parent:
                        raise RuntimeError('Owned descendant parent changed')
                    else:
                        parent_snapshot = self.snapshot(parent)
                        if parent_snapshot is None or parent_snapshot[:5] != active[parent]:
                            raise RuntimeError('Owned parent identity changed before admission')
                    if self.lifetime_count() - (pid in self.pending_children) >= 4096:
                        raise RuntimeError('Owned lifetime process bound exceeded')
                    if len(active) + len(self.pending_children) + len(self.exiting_processes) - (pid in self.pending_children) >= 64:
                        raise RuntimeError('Owned concurrent descendant bound exceeded')
                    self.seals[pid] = seal
                    if pid != self.leader:
                        self.admission_parents[pid] = parent_snapshot + (self.uid, self.uid)
                        self.parents[pid] = parent
                    self.pending_children.pop(pid, None)
                prior = self.known.get(pid)
                if prior is not None and prior[3] != identity[3]:
                    if len(self.transitions) >= 1024:
                        raise RuntimeError('Owned executable transition bound exceeded')
                    self.transitions.append({'previous': prior, 'current': identity})
                if len(active) + len(self.pending_children) + len(self.exiting_processes) >= 64:
                    raise RuntimeError('Owned concurrent descendant bound exceeded')
                self.known[pid] = identity
                active[pid] = identity
                children = (ctypes.c_int * 64)()
                count = self.library.proc_listchildpids(pid, children, ctypes.sizeof(children))
                if count < 0 or count >= len(children):
                    raise RuntimeError('Invalid owned child enumeration')
                pending.extend((children[index], pid) for index in range(count))
            except (OSError, RuntimeError) as error:
                if pid in self.pending_children:
                    self.pending_failures.add(pid)
                self.reject(pid, str(error))
        return list(active.values())

    def conflicts(self):
        return list(self.rejected.values())

    def verified(self, identity):
        try:
            current = self.identity(identity[0])
            if current is not None and current != identity:
                self.reject(identity[0], 'Owned identity changed before signal')
            return current == identity
        except (OSError, RuntimeError) as error:
            self.reject(identity[0], str(error))
            return False

    def terminate(self, value):
        for identity in self.refresh():
            if self.verified(identity):
                try:
                    os.kill(identity[0], value)
                except ProcessLookupError:
                    pass


def retire_unobserved(process):
    for value in (signal.SIGTERM, signal.SIGKILL):
        try:
            if os.getpgid(process.pid) == process.pid:
                os.killpg(process.pid, value)
        except ProcessLookupError:
            pass
    process.wait(timeout=5)


def admit(environment, source):
    expected = environment.get('EXPECTED_SOURCE_SHA', '')
    owner = environment.get('NATIVE_TEST_OWNER', '')
    required = {
        'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS',
        'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
        'GITHUB_REPOSITORY': 'pulkitxm/edith', 'GITHUB_REPOSITORY_ID': '1289153439',
        'EDITH_HOSTED_NATIVE_OWNER_TESTS': '1',
        'EDITH_HOSTED_RELEASE': 'false', 'EDITH_HOSTED_REBUILD': '',
    }
    if (any(environment.get(key) != value for key, value in required.items())
            or environment.get('GITHUB_ACTOR_ID') not in ('65671483', '320458784')
            or environment.get('GITHUB_REF') not in (
                'refs/heads/feat/extension-marketplace', 'refs/heads/main')
            or re.fullmatch('[0-9a-f]{40}', expected) is None
            or expected != environment.get('GITHUB_SHA') or expected != source
            or owner not in TARGETS):
        raise ValueError('Original native tests require exact-source disposable hosted admission')
    return owner


def original_command(owner, definitions):
    targets = TARGETS[owner]
    if owner != 'feature-models':
        original_owner = 'database' if owner in DATABASE_DIAGNOSTICS else owner
        original_targets = ['ci-extension-database'] if owner in DATABASE_DIAGNOSTICS else targets
        selected = [definition for definition in definitions if definition.get('id') == original_owner]
        if len(selected) != 1 or selected[0].get('testTargets') != original_targets:
            raise ValueError('Original owner test target contract changed')
    return ['make', *targets]


def database_completed(text, owner):
    if owner not in DATABASE_DIAGNOSTICS:
        raise ValueError('Unknown database diagnostic selection')
    duration = r'[0-9]+(?:\.[0-9]+)?'
    start = re.search(r'^◇ Suite DatabaseExecutorTests started\.$', text, re.MULTILINE)
    if start is None:
        return False
    end = re.search(
        r'^✔ Suite DatabaseExecutorTests passed after ' + duration + r' seconds?\.$',
        text[start.end():], re.MULTILINE)
    if end is None:
        return False
    suite = text[start.end():start.end() + end.start()]
    if re.search(r'^[✘✗]|^.*(?:Issue recorded|failed after)', text, re.MULTILINE):
        return False
    summary = re.search(
        r'^✔ Test run with ([1-9][0-9]*) tests? in [1-9][0-9]* suites? passed after '
        + duration + r' seconds?\.$', text, re.MULTILINE)
    if summary is None or summary.start() <= start.end() + end.end():
        return False
    if owner == 'database-mutation':
        name = 'mutationPreviewNormalizesWithoutExecuting'
        starts = re.findall(r'^◇ Test ([A-Za-z0-9_]+)\(\) started\.$', suite, re.MULTILINE)
        passes = re.findall(
            r'^✔ Test ([A-Za-z0-9_]+)\(\) passed after ' + duration + r' seconds?\.$',
            suite, re.MULTILINE)
        return starts == [name] and passes == [name] and int(summary.group(1)) == 1
    return bool(re.search(r'^◇ Test .+ started\.$', suite, re.MULTILINE)
                and re.search(r'^✔ Test .+ passed after ' + duration + r' seconds?\.$',
                              suite, re.MULTILINE))


def testing_process(path):
    name = Path(path).name
    return name in ('swiftpm-testing', 'swiftpm-testing-helper') or name.endswith('PackageTests')


def retire(process, ownership, clock, sleep):
    natural_survivors = ownership.refresh()
    conflicts = ownership.conflicts()
    if natural_survivors:
        ownership.terminate(signal.SIGTERM)
        deadline = clock() + 5
        while ownership.refresh() and clock() < deadline:
            sleep(0.1)
        ownership.terminate(signal.SIGKILL)
    reaped = True
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        ownership.terminate(signal.SIGKILL)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            reaped = False
    joined_cleanup = getattr(ownership, 'begin_joined_cleanup', None)
    if joined_cleanup is not None:
        joined_cleanup(reaped)
    deadline = clock() + 5
    while (ownership.refresh() or getattr(ownership, 'exiting_processes', {})) and clock() < deadline:
        sleep(0.1)
    remaining = ownership.refresh()
    finalize_exiting = getattr(ownership, 'finalize_exiting_processes', None)
    if finalize_exiting is not None:
        finalize_exiting(reaped)
    finalize_pending = getattr(ownership, 'finalize_pending_children', None)
    if finalize_pending is not None:
        finalize_pending(reaped)
    return {
        'naturalSurvivorCount': len(natural_survivors), 'reaped': reaped,
        'remainingOwnedProcesses': len(remaining),
        'unverifiedOwnedProcesses': len(conflicts),
        'pendingOwnedChildren': len(getattr(ownership, 'pending_children', {})) + len(getattr(ownership, 'exiting_processes', {})),
        'ownershipErrors': getattr(ownership, 'errors', []),
    }


def run_original(arguments, root, environment, output, deadline=TEST_DEADLINE,
                 process_factory=subprocess.Popen, ownership_factory=BoundedOwnership,
                 clock=time.monotonic, sleep=time.sleep, sample=subprocess.run, selection=None,
                 testing_process=testing_process):
    if selection is not None and selection not in DATABASE_DIAGNOSTICS:
        raise ValueError('Unknown database diagnostic selection')
    started = clock()
    wall_start = time.time()
    log_path = output / 'tests.log'
    observed = set()
    timed_out = False
    overflow = False
    failure = None
    with log_path.open('wb') as log, (output / 'processes.jsonl').open('w') as timeline:
        process = process_factory(
            arguments, cwd=root, env=environment, stdout=log,
            stderr=subprocess.STDOUT, start_new_session=True)
        try:
            ownership = ownership_factory(process.pid, os.getuid())
        except Exception:
            retire_unobserved(process)
            raise
        next_heartbeat = started
        try:
            while True:
                current = ownership.refresh()
                newly_seen = [identity for identity in current if identity not in observed]
                observed.update(current)
                now = clock()
                if newly_seen or now >= next_heartbeat:
                    timeline.write(json.dumps({
                        'elapsedSeconds': round(now - started, 3),
                        'newOwnedProcesses': newly_seen, 'activeOwnedProcesses': current,
                        'logBytes': log_path.stat().st_size,
                        'parentExitCode': process.poll(),
                    }) + '\n')
                    timeline.flush()
                    next_heartbeat = now + 30
                if process.poll() is not None:
                    break
                overflow = log_path.stat().st_size > LOG_BOUND
                timed_out = now - started >= deadline
                if timed_out or overflow:
                    ownership.terminate(signal.SIGSTOP)
                    for index, identity in enumerate(
                            [item for item in current if testing_process(item[3])][:2]):
                        if ownership.identity(identity[0]) == identity:
                            try:
                                sample(
                                    ['/usr/bin/sample', str(identity[0]), '3', '-file',
                                     str(output / f'owned-test-{index}.sample')],
                                    timeout=10, check=False, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
                            except (OSError, subprocess.TimeoutExpired) as error:
                                timeline.write(json.dumps({'sampleFailure': str(error)}) + '\n')
                                timeline.flush()
                    break
                sleep(0.5)
        except Exception as error:
            failure = str(error)
        finally:
            cleanup = retire(process, ownership, clock, sleep)
            roles = getattr(ownership, 'private_failure_pid_roles', {})
            if type(roles) is dict and 0 < len(roles) <= 8:
                timeline.write(json.dumps({'failurePIDRoles': [
                    {'pid': pid, 'role': role} for pid, role in list(roles.items())[:8]
                    if type(pid) is int and pid > 0 and type(role) is str and role in {'leader', 'known', 'unsealed'}
                ]}) + '\n')
                timeline.flush()
    if log_path.stat().st_size > LOG_BOUND:
        with log_path.open('r+b') as bounded:
            bounded.truncate(LOG_BOUND)
    for path in output.glob('*.sample'):
        if path.stat().st_size > 8_388_608:
            path.write_text('Owned test process sample exceeded its diagnostic bound.\n')
    text = log_path.read_text(errors='replace')
    completed = bool(re.search(
        r'Test run with [1-9][0-9]* tests? (?:in [1-9][0-9]* suites? )?passed|Executed [1-9][0-9]* tests?, with 0 failures',
        text))
    if selection is not None:
        completed = completed and database_completed(text, selection)
    code = 124 if timed_out else 1 if overflow or failure else process.returncode
    observed_testing = any(testing_process(item[3]) for item in observed)
    passed = (code == 0 and completed and observed_testing and cleanup['naturalSurvivorCount'] == 0
              and cleanup['reaped'] and cleanup['remainingOwnedProcesses'] == 0
              and cleanup['unverifiedOwnedProcesses'] == 0 and not cleanup['ownershipErrors'])
    return {
        'argv': arguments, 'exitCode': code, 'passed': passed, 'timedOut': timed_out,
        'logBoundExceeded': overflow, 'failure': failure,
        'testsCompleted': completed, 'durationSeconds': round(clock() - started, 3),
        'observedTestingProcess': observed_testing,
        'ownedExecutableTransitions': getattr(ownership, 'transitions', []),
        'ownershipFailureObservations': getattr(ownership, 'failure_observations', []),
        'childSelfGroupObservations': list(getattr(ownership, 'self_group_observations', {}).values()),
        'capturedSnapshotFailures': getattr(ownership, 'captured_snapshot_failures', []),
        'knownOwnedProcesses': list(observed), 'cleanup': cleanup,
        'logSHA256': hashlib.sha256(log_path.read_bytes()).hexdigest(),
        'ownedCrashReports': watchdog.owned_crash_reports(
            Path.home() / 'Library/Logs/DiagnosticReports', output, list(observed), wall_start),
    }


def interrupted(signum, frame):
    raise InterruptedError(f'Hosted native test runner received signal {signum}')


def main():
    if sys.argv[1:]:
        raise ValueError('Unexpected native owner test arguments')
    root = Path(__file__).resolve().parent.parent
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    owner = admit(os.environ, source)
    manifest = root / 'Extensions/manifest.json'
    command = original_command(owner, json.loads(manifest.read_text()))
    output = root / 'local/hosted-native-owner-tests'
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    outcome = {
        'schema': 1, 'owner': owner, 'sourceCommit': source,
        'manifestSHA256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
        'commandDeadlineSeconds': TEST_DEADLINE,
        'passed': False,
    }
    fixture = Path(tempfile.mkdtemp(prefix='edith-owner-tests-', dir=os.environ['RUNNER_TEMP']))
    home = fixture / 'home'
    home.mkdir(mode=0o700)
    environment = {key: value for key, value in os.environ.items() if not key.startswith('EDITH_')}
    environment.update({
        'HOME': str(home), 'CFFIXED_USER_HOME': str(home), 'TMPDIR': str(fixture) + '/',
        'EXTENSION_SWIFT_JOBS': '1', 'EDITH_MAKE_GATE': 'skip',
        'NSUnbufferedIO': 'YES', 'NO_COLOR': '1',
    })
    previous_handlers = {value: signal.signal(value, interrupted) for value in (signal.SIGTERM, signal.SIGINT)}
    try:
        outcome['toolchain'] = {
            name: subprocess.check_output(arguments, text=True, timeout=30).strip()
            for name, arguments in [
                ('swift', ['swift', '--version']), ('xcode', ['xcodebuild', '-version']),
                ('sdk', ['xcrun', '--sdk', 'macosx', '--show-sdk-version']),
            ]
        }
        environment['DEVELOPER_DIR'] = subprocess.check_output(
            ['xcode-select', '-p'], text=True, timeout=30).strip()
        outcome['result'] = run_original(
            command, root, environment, output,
            selection=owner if owner in DATABASE_DIAGNOSTICS else None)
        outcome['passed'] = outcome['result']['passed']
    except Exception as error:
        outcome['failure'] = str(error)
    finally:
        (output / 'outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
        for value, handler in previous_handlers.items():
            signal.signal(value, handler)
        shutil.rmtree(fixture)
    print(json.dumps(outcome))
    return 0 if outcome['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
