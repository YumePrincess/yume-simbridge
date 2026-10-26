import sys, unittest, socket, struct
from pathlib import Path
from unittest.mock import patch,MagicMock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import adb_server as server

class SharedADBTest(unittest.TestCase):
    def test_match_physical_usb_location_not_phone_order_or_duplicate_serial(self):
        listing='phone device usb:999X transport_id:7\n(no serial number) device usb:137560064X transport_id:3\n127.0.0.1:5555 device transport_id:8\n'
        self.assertEqual(server.select_transport(listing,{'137560064X'}),3)
        for bad in ['phone device usb:999X transport_id:7','(no serial number) offline usb:137560064X transport_id:3',listing+listing]:
            with self.assertRaises(server.ServerError):server.select_transport(bad,{'137560064X'})
    def test_changed_transport_is_rejected_before_any_shell_or_push(self):
        client=server.ServerADB.__new__(server.ServerADB)
        client.transport=3;client.paths={'137560064X'}
        with patch.object(client,'query',return_value='usb:OTHER'),patch.object(client,'connect') as connect:
            with self.assertRaises(server.ServerError):client.stream('sync:',5)
        connect.assert_not_called()
    def test_smart_socket_handles_fragmented_responses_and_errors(self):
        sock=MagicMock()
        sock.recv.side_effect=[b'O',b'K',b'AY']
        server.request(sock,'host:devices-l')
        sock.sendall.assert_called_once_with(b'000ehost:devices-l')
        sock.recv.side_effect=[b'FAIL',b'0004',b'busy']
        with self.assertRaisesRegex(server.ServerError,'busy'):server.request(sock,'host:devices-l')
    def test_shell_enforces_identity_in_the_same_command(self):
        client=server.ServerADB.__new__(server.ServerADB)
        client.vendor=0x2ca3;client.product=0x4006
        sock=MagicMock();sock.__enter__.return_value=sock
        # Fixed nonce lets the fake peer return the real status framing.
        sock.recv.side_effect=[b'Linux\r\n\n__SIMHUB_'+b'01'*12+b'_0__\n',b'']
        with patch.object(server.os,'urandom',return_value=b'\x01'*12),patch.object(client,'stream',return_value=sock) as stream:
            self.assertEqual(client.shell_checked('uname -r')[1],0)
        command=stream.call_args.args[0]
        self.assertIn('idVendor',command);self.assertIn('"2ca3"',command)
        self.assertLess(command.index('idVendor'),command.index('uname -r'))
    def test_sync_push_uses_stream_protocol_with_ack(self):
        client=server.ServerADB.__new__(server.ServerADB)
        sock=MagicMock();sock.__enter__.return_value=sock
        sock.recv.side_effect=[b'OKAY',struct.pack('<I',0)]
        with patch.object(client,'stream',return_value=sock):client.push(b'abc','/tmp/mavo-call/test',0o100600)
        payloads=[x.args[0] for x in sock.sendall.call_args_list]
        self.assertTrue(payloads[0].startswith(b'SEND'))
        self.assertEqual(payloads[1],b'DATA\x03\x00\x00\x00abc')
        self.assertTrue(payloads[-1].startswith(b'QUIT'))
