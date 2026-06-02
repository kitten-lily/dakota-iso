import sys
import os
import unittest
from unittest.mock import patch, MagicMock, mock_open

# Dynamically import luks-unlock.py which has a hyphen in its name
import importlib.util

spec = importlib.util.spec_from_file_location(
    "luks_unlock",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "../dakota/src/luks-unlock.py"))
)
luks_unlock = importlib.util.module_from_spec(spec)
sys.modules["luks_unlock"] = luks_unlock
spec.loader.exec_module(luks_unlock)


class TestLuksUnlock(unittest.TestCase):

    # ── qemu_check_serial Tests ────────────────────────────────────────────────

    @patch("builtins.open", new_callable=mock_open)
    def test_qemu_check_serial_file_not_found(self, mock_file):
        # If the file does not exist, it should return "" gracefully
        mock_file.side_effect = FileNotFoundError()
        result = luks_unlock.qemu_check_serial("dummy.log")
        self.assertEqual(result, "")

    @patch("builtins.open", new_callable=mock_open, read_data="Please enter passphrase for disk /dev/vda:")
    def test_qemu_check_serial_plymouth(self, mock_file):
        # Check that it identifies "plymouth" passphrase prompt
        result = luks_unlock.qemu_check_serial("dummy.log")
        self.assertEqual(result, "plymouth")

    @patch("builtins.open", new_callable=mock_open, read_data="[  OK  ] Started gdm.service - GNOME Display Manager.")
    def test_qemu_check_serial_gdm_started(self, mock_file):
        # Check that it identifies "gdm" when service starts
        result = luks_unlock.qemu_check_serial("dummy.log")
        self.assertEqual(result, "gdm")

    @patch("builtins.open", new_callable=mock_open, read_data="Started GNOME Display Manager.")
    def test_qemu_check_serial_gdm_display_manager(self, mock_file):
        # Check that it identifies "gdm" with alternate display manager string
        result = luks_unlock.qemu_check_serial("dummy.log")
        self.assertEqual(result, "gdm")

    @patch("builtins.open", new_callable=mock_open, read_data="\x1b[1;31m  OK  ] Started \x1b[0m\ngdm.service\n- GNOME Display…")
    def test_qemu_check_serial_gdm_with_ansi_escapes(self, mock_file):
        # Check that it strips ANSI escape codes and collapses whitespace
        result = luks_unlock.qemu_check_serial("dummy.log")
        self.assertEqual(result, "gdm")

    @patch("builtins.open", new_callable=mock_open, read_data="[  OK  ] Started gnome-initial-setup.service - GNOME Initial Setup.")
    def test_qemu_check_serial_gnome_initial_setup(self, mock_file):
        # Check that it identifies "gnome-initial-setup"
        result = luks_unlock.qemu_check_serial("dummy.log")
        self.assertEqual(result, "gnome-initial-setup")

    @patch("builtins.open", new_callable=mock_open, read_data="Entering emergency mode. Exit shell to continue.")
    def test_qemu_check_serial_emergency_mode(self, mock_file):
        # Check that it identifies "emergency"
        result = luks_unlock.qemu_check_serial("dummy.log")
        self.assertEqual(result, "emergency")

    @patch("builtins.open", new_callable=mock_open, read_data="Some other boot log lines with no markers...")
    def test_qemu_check_serial_no_marker(self, mock_file):
        # Check that it returns empty string if no markers are present
        result = luks_unlock.qemu_check_serial("dummy.log")
        self.assertEqual(result, "")

    # ── virsh_dhcp_ip Tests ────────────────────────────────────────────────────

    @patch("subprocess.run")
    def test_virsh_dhcp_ip_found(self, mock_run):
        # Mock subprocess to return lease table output
        mock_proc = MagicMock()
        mock_proc.stdout = (
            " Expiry Time          MAC address        Protocol  IP address                Hostname        Client ID or DUID\n"
            "-------------------------------------------------------------------------------------------------------------------\n"
            " 2026-05-31 15:00:00  52:54:00:fa:12:34  ipv4      192.168.122.42/24         dakota-vm       01:52:54:00:fa:12:34\n"
        )
        mock_run.return_value = mock_proc

        result = luks_unlock.virsh_dhcp_ip("52:54:00:fa:12:34")
        self.assertEqual(result, "192.168.122.42")

        # Verify case insensitivity
        result_caps = luks_unlock.virsh_dhcp_ip("52:54:00:FA:12:34")
        self.assertEqual(result_caps, "192.168.122.42")

    @patch("subprocess.run")
    def test_virsh_dhcp_ip_not_found(self, mock_run):
        mock_proc = MagicMock()
        mock_proc.stdout = (
            " Expiry Time          MAC address        Protocol  IP address                Hostname        Client ID or DUID\n"
            "-------------------------------------------------------------------------------------------------------------------\n"
            " 2026-05-31 15:00:00  52:54:00:fa:12:34  ipv4      192.168.122.42/24         dakota-vm       01:52:54:00:fa:12:34\n"
        )
        mock_run.return_value = mock_proc

        result = luks_unlock.virsh_dhcp_ip("00:11:22:33:44:55")
        self.assertEqual(result, "")

    # ── virsh_send_passphrase Tests ────────────────────────────────────────────

    @patch("time.sleep")  # Patch sleep so tests run instantly
    @patch("subprocess.run")
    def test_virsh_send_passphrase_valid(self, mock_run, mock_sleep):
        luks_unlock.virsh_send_passphrase("myvm", "abc-1")

        # abc-1 translates to KEY_A, KEY_B, KEY_C, KEY_MINUS, KEY_1, followed by KEY_ENTER
        expected_calls = [
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_A"],),
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_B"],),
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_C"],),
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_MINUS"],),
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_1"],),
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_ENTER"],)
        ]

        # Extract only call arguments
        actual_calls = [call[0] for call in mock_run.call_args_list]
        self.assertEqual(actual_calls, expected_calls)

    @patch("time.sleep")
    @patch("subprocess.run")
    def test_virsh_send_passphrase_edge_cases(self, mock_run, mock_sleep):
        # Test spaces, underscores, uppercase (skipped) and special chars (skipped)
        luks_unlock.virsh_send_passphrase("myvm", "a_B $")

        # 'a' -> KEY_A
        # '_' -> KEY_MINUS
        # 'B' -> skipped (only lowercase is mapped in key_map)
        # ' ' -> KEY_SPACE
        # '$' -> skipped
        # Always followed by KEY_ENTER
        expected_calls = [
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_A"],),
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_MINUS"],),
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_SPACE"],),
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_ENTER"],)
        ]
        actual_calls = [call[0] for call in mock_run.call_args_list]
        self.assertEqual(actual_calls, expected_calls)

    @patch("time.sleep")
    @patch("subprocess.run")
    def test_virsh_send_passphrase_empty(self, mock_run, mock_sleep):
        # Empty passphrase should only send KEY_ENTER
        luks_unlock.virsh_send_passphrase("myvm", "")
        expected_calls = [
            (["virsh", "send-key", "myvm", "--codeset", "linux", "KEY_ENTER"],)
        ]
        actual_calls = [call[0] for call in mock_run.call_args_list]
        self.assertEqual(actual_calls, expected_calls)

    # ── qemu_send_passphrase Tests ────────────────────────────────────────────

    @patch("time.sleep")
    @patch("subprocess.run")
    def test_qemu_send_passphrase_valid(self, mock_run, mock_sleep):
        luks_unlock.qemu_send_passphrase("/tmp/sock", "abc-1")

        # abc-1 translates to keys: a, b, c, minus, 1, followed by ret
        expected_calls = [
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey a\n"),
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey b\n"),
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey c\n"),
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey minus\n"),
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey 1\n"),
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey ret\n")
        ]

        actual_calls = [(call[0][0], call[1].get("input")) for call in mock_run.call_args_list]
        self.assertEqual(actual_calls, expected_calls)

    @patch("time.sleep")
    @patch("subprocess.run")
    def test_qemu_send_passphrase_edge_cases(self, mock_run, mock_sleep):
        # Test spaces, underscores, uppercase (skipped) and special chars (skipped)
        luks_unlock.qemu_send_passphrase("/tmp/sock", "a_B $")

        # 'a' -> a
        # '_' -> shift-minus
        # 'B' -> skipped (uppercase not in map)
        # ' ' -> spc
        # '$' -> skipped
        # Always followed by ret
        expected_calls = [
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey a\n"),
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey shift-minus\n"),
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey spc\n"),
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey ret\n")
        ]
        actual_calls = [(call[0][0], call[1].get("input")) for call in mock_run.call_args_list]
        self.assertEqual(actual_calls, expected_calls)

    @patch("time.sleep")
    @patch("subprocess.run")
    def test_qemu_send_passphrase_empty(self, mock_run, mock_sleep):
        # Empty passphrase should only send ret
        luks_unlock.qemu_send_passphrase("/tmp/sock", "")
        expected_calls = [
            (["socat", "-", "UNIX-CONNECT:/tmp/sock"], b"sendkey ret\n")
        ]
        actual_calls = [(call[0][0], call[1].get("input")) for call in mock_run.call_args_list]
        self.assertEqual(actual_calls, expected_calls)

    # ── main() Routing Tests ───────────────────────────────────────────────────

    @patch("sys.exit")
    def test_main_no_args(self, mock_exit):
        mock_exit.side_effect = SystemExit(1)
        with patch("sys.argv", ["luks-unlock.py"]):
            with self.assertRaises(SystemExit):
                luks_unlock.main()
            mock_exit.assert_called_once_with(1)

    @patch("sys.exit")
    def test_main_invalid_mode(self, mock_exit):
        mock_exit.side_effect = SystemExit(1)
        with patch("sys.argv", ["luks-unlock.py", "invalid_mode"]):
            with self.assertRaises(SystemExit):
                luks_unlock.main()
            mock_exit.assert_called_once_with(1)

    @patch("sys.exit")
    def test_main_libvirt_insufficient_args(self, mock_exit):
        mock_exit.side_effect = SystemExit(1)
        with patch("sys.argv", ["luks-unlock.py", "libvirt", "vm-name"]):
            with self.assertRaises(SystemExit):
                luks_unlock.main()
            mock_exit.assert_called_once_with(1)

    @patch("sys.exit")
    def test_main_qemu_insufficient_args(self, mock_exit):
        mock_exit.side_effect = SystemExit(1)
        with patch("sys.argv", ["luks-unlock.py", "qemu", "/tmp/sock"]):
            with self.assertRaises(SystemExit):
                luks_unlock.main()
            mock_exit.assert_called_once_with(1)

    @patch("sys.exit")
    @patch("luks_unlock.run_libvirt")
    def test_main_libvirt_success(self, mock_run_libvirt, mock_exit):
        with patch("sys.argv", ["luks-unlock.py", "libvirt", "myvm", "pass123", "52:54:00:fa:12:34"]):
            luks_unlock.main()
            mock_run_libvirt.assert_called_once_with("myvm", "pass123", "52:54:00:fa:12:34")
            mock_exit.assert_not_called()

    @patch("sys.exit")
    @patch("luks_unlock.run_qemu")
    def test_main_qemu_success(self, mock_run_qemu, mock_exit):
        with patch("sys.argv", ["luks-unlock.py", "qemu", "/tmp/sock", "pass123", "/tmp/serial.log"]):
            luks_unlock.main()
            mock_run_qemu.assert_called_once_with("/tmp/sock", "pass123", "/tmp/serial.log")
            mock_exit.assert_not_called()

    @patch("sys.exit")
    def test_main_wait_live_insufficient_args(self, mock_exit):
        mock_exit.side_effect = SystemExit(1)
        with patch("sys.argv", ["luks-unlock.py", "wait-live", "/tmp/sock"]):
            with self.assertRaises(SystemExit):
                luks_unlock.main()
            mock_exit.assert_called_once_with(1)

    @patch("sys.exit")
    @patch("luks_unlock.run_wait_live")
    def test_main_wait_live_success(self, mock_run_wait_live, mock_exit):
        with patch("sys.argv", ["luks-unlock.py", "wait-live", "/tmp/sock", "/tmp/screenshot.ppm"]):
            luks_unlock.main()
            mock_run_wait_live.assert_called_once_with("/tmp/sock", "/tmp/screenshot.ppm")
            mock_exit.assert_not_called()

    @patch("luks_unlock.qemu_screendump")
    @patch("time.sleep")
    @patch("shutil.copy2")
    def test_run_wait_live_success(self, mock_copy, mock_sleep, mock_screendump):
        mock_screendump.side_effect = [
            (0.1, 'a'),
            (2.0, 'b'),
            (2.0, 'b'),
            (2.0, 'b')
        ]
        luks_unlock.run_wait_live("/tmp/sock", "/tmp/screenshot.ppm")
        self.assertEqual(mock_screendump.call_count, 4)
        mock_copy.assert_called_with("/tmp/luks-live-boot-snap.ppm", "/tmp/screenshot.ppm")

    @patch("luks_unlock.qemu_screendump")
    @patch("time.sleep")
    @patch("shutil.copy2")
    def test_run_wait_live_timeout(self, mock_copy, mock_sleep, mock_screendump):
        # Always dark, or never stable
        mock_screendump.return_value = (0.1, 'a')
        with patch("time.time", side_effect=[0, 100, 200, 301]):
            luks_unlock.run_wait_live("/tmp/sock", "/tmp/screenshot.ppm")
        # Should not copy since brightness < threshold
        mock_copy.assert_not_called()


if __name__ == "__main__":
    unittest.main()
