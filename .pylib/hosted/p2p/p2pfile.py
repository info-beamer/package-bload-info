#
# Part of info-beamer hosted. You can find the latest version
# of this file at:
#
# https://github.com/info-beamer/package-sdk
#
# Copyright (c) 2023 Florian Wesch <fw@info-beamer.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
#     Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#
#     Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the
#     distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
# IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

VERSION = "1.0"
import select, socket, sys, re, os, hmac, hashlib, struct, errno, tempfile, threading
from contextlib import contextmanager
from Crypto.Util import Counter
from Crypto.Cipher import AES
from binascii import unhexlify, hexlify
from cStringIO import StringIO

def log(msg, name='p2pfile.py'):
    print >>sys.stderr, "[{}] {}".format(name, msg)

class ClientIO(object):
    def __init__(self, pair_key, conn):
        self._pair_key = pair_key
        self._conn = conn
        self._request_mode = True

        self._buf = None
        self._buf_remaining = None

        self._outstream_remaining = None
        self._outstream = None

    def start_read(self, size):
        self._request_mode = True
        self._buf = ''
        self._buf_remaining = size

    def start_write(self, response_key, size, stream):
        self._request_mode = False

        iv = os.urandom(16)
        self._cipher = AES.new(
            hmac.HMAC(
                self._pair_key,
                response_key + iv,
                hashlib.sha256
            ).digest()[:16],
            AES.MODE_CTR,
            counter=Counter.new(128, initial_value=0)
        )
        self._outstream_remaining = size
        self._outstream = stream

        # send plaintext header
        self._buf = struct.pack("<16sL", iv, size)
        self._buf_remaining = len(self._buf)

    def read(self):
        assert self._request_mode
        assert self._buf_remaining > 0
        try:
            chunk = self._conn.recv(self._buf_remaining)
        except socket.error:
            return False, None
        if not chunk: # closed?
            return False, None
        self._buf += chunk
        self._buf_remaining -= len(chunk)
        if self._buf_remaining == 0:
            request = self._buf
            self._buf = None
            return True, request
        else:
            return True, None

    def write(self):
        assert not self._request_mode
        while 1:
            if self._buf is None:
                if self._outstream_remaining == 0:
                    break
                chunk = self._outstream.read(
                    min(self._outstream_remaining, 16384
                ))
                if not chunk:
                    break
                self._buf = self._cipher.encrypt(chunk)
                self._buf_remaining = len(self._buf)
                self._outstream_remaining -= len(self._buf)
            assert len(self._buf) > 0
            try:
                written = self._conn.send(self._buf)
            except socket.error as e:
                if e.errno == errno.EAGAIN:
                    return True, False
                else:
                    return False, False # error sending
            self._buf_remaining -= written
            self._buf = self._buf[written:]
            if self._buf:
                return True, False
            self._buf = None # all written
        if self._outstream:
            self._outstream.close()
        self._outstream = None
        self._outstream_remaining = None
        return True, True

    def close(self):
        if self._outstream:
            self._outstream.close()
        self._conn.close()

class TCPServer(object):
    def __init__(self, port):
        self._e = select.epoll()
        self._listen_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listen_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listen_sock.bind(('0.0.0.0', port))
        self._listen_sock.setblocking(False)
        self._listen_sock.listen(1)
        self._listen_fd = self._listen_sock.fileno()
        self._e.register(self._listen_fd, select.EPOLLIN)
        self._clients = {}
        self._request_size = self.setup()

    def setup(self):
        raise NotImplementedError

    def accept_client(self, addr):
        return None

    def handle_request(self, request):
        raise NotImplementedError

    def shutdown(self):
        pass

    def run(self, timeout=-1):
        try:
            events = self._e.poll(timeout)
        except IOError as err:
            if err.errno == errno.EINTR:
                return
        for fd, event in events:
            if fd == self._listen_fd:
                conn, addr = self._listen_sock.accept()
                conn.setblocking(False)
                pair_key = self.accept_client(addr)
                if pair_key is None:
                    conn.close()
                    continue
                client = ClientIO(pair_key, conn)
                conn_fd = conn.fileno()
                self._clients[conn_fd] = client
                client.start_read(self._request_size)
                self._e.register(conn_fd, select.EPOLLIN)
            elif event & select.EPOLLIN:
                client = self._clients[fd]
                success, request = client.read()
                if not success:
                    self._e.unregister(fd)
                    client.close()
                    del self._clients[fd]
                elif request:
                    response_key, response_size, response_stream = self.handle_request(request)
                    client.start_write(response_key, response_size, response_stream)
                    self._e.modify(fd, select.EPOLLOUT)
            elif event & select.EPOLLOUT:
                client = self._clients[fd]
                success, sent = client.write()
                if not success:
                    self._e.unregister(fd)
                    client.close()
                    del self._clients[fd]
                elif sent:
                    client.start_read(self._request_size)
                    self._e.modify(fd, select.EPOLLIN)

    def close(self):
        self.shutdown()
        for client_fd, client in self._clients.iteritems():
            self._e.unregister(client_fd)
            client.close()
        self._e.unregister(self._listen_fd)
        self._listen_sock.close()
        self._e.close()


def change_seq_to_hex(change_seq):
    return hexlify(struct.pack(">Q", change_seq))
def change_seq_from_hex(change_seq_hex):
    change_seq, = struct.unpack(">Q", unhexlify(change_seq_hex))
    return change_seq

class ChunkServer(TCPServer):
    def setup(self):
        self._lock = threading.RLock()
        self._files = {}
        self._change_seq_to_fname = {}
        self._change_seq = 0
        for fname in os.listdir("."):
            m = re.match(r"^.p2p-chunk-[a-f0-9]{16}-[a-f0-9]{64}$", fname)
            if not m:
                continue
            os.unlink(fname)
        return 8

    @contextmanager
    def create(self, fname):
        tmp = tempfile.NamedTemporaryFile(dir='.', prefix='.p2p-write-')
        try:
            yield tmp, self._change_seq + 1
            tmp.delete = False
            size = tmp.tell()
            tmp.seek(0)
            h = hashlib.sha256()
            while 1:
                chunk = tmp.read(16384)
                if not chunk:
                    break
                h.update(chunk)
            chunk_hash = h.digest()
            chunk_fname = ".p2p-chunk-%s-%s" % (
                change_seq_to_hex(self._change_seq + 1),
                h.hexdigest(),
            )
            with self._lock:
                try:
                    os.rename(tmp.name, chunk_fname)
                    tmp.delete = False
                except OSError as err:
                    if err.errno != errno.EEXIST:
                        raise
                self.delete(fname)
                self._change_seq += 1
                self._files[fname] = self._change_seq, chunk_hash, chunk_fname, size
                self._change_seq_to_fname[self._change_seq] = chunk_fname
        finally:
            tmp.close()

    def delete(self, fname):
        with self._lock:
            if not fname in self._files:
                return False
            old_seq, old_hash, old_fname, old_size = self._files[fname]
            os.unlink(old_fname)
            del self._files[fname]
            del self._change_seq_to_fname[old_seq]
        return True

    def accept_client(self, addr):
        host, port = addr
        log('new client from %s:%d' % (host, port))
        return 'secret'

    def handle_request(self, raw_change_seq):
        change_seq, = struct.unpack(">Q", raw_change_seq)
        log('serving %s' % change_seq_to_hex(change_seq))
        if change_seq == 0:
            out = StringIO()
            with self._lock:
                for chunk_change_seq, chunk_hash, chunk_fname, chunk_size in sorted(self._files.itervalues()):
                    out.write(struct.pack(">QL32s", chunk_change_seq, chunk_size, chunk_hash))
            size = out.tell()
            out.seek(0)
            return 'index', size, out
        try:
            f = open(self._change_seq_to_fname[change_seq], 'rb')
            size = os.fstat(f.fileno()).st_size
            return str(change_seq), size, f
        except:
            log('chunk %s not found' % change_seq_to_hex(change_seq))
            return '', 0, None

class SyncError(Exception):
    pass

class ChunkClient(object):
    def __init__(self):
        self._change_seqs = {}

    def sync(self, pair_key, server_addr, server_port, timeout=1):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect((server_addr, server_port))
        except Exception as err:
            raise SyncError(err)

        def receive_chunk(change_seq, response_key, target, min_size, max_size):
            sock.send(struct.pack(">Q", change_seq))
            iv, chunk_size, = struct.unpack("<16sL", sock.recv(20))
            if chunk_size < min_size:
                return None
            if chunk_size > max_size:
                return None
            cipher = AES.new(
                hmac.HMAC(
                    pair_key,
                    response_key + iv,
                    hashlib.sha256
                ).digest()[:16],
                AES.MODE_CTR,
                counter=Counter.new(128, initial_value=0)
            )
            h = hashlib.sha256()
            remaining = chunk_size
            while remaining > 0:
                try:
                    chunk = sock.recv(min(remaining, 16384))
                except Exception as err:
                    raise SyncError(err)
                if not chunk:
                    return
                remaining -= len(chunk)
                plain = cipher.decrypt(chunk)
                h.update(plain)
                target.write(plain)
            return h.digest()

        chunks = StringIO()
        if not receive_chunk(0, 'index', chunks, 0, 44*1024):
            return SyncError("cannot fetch index")
        chunks.seek(0, 0)
        change_seqs = {}
        latest_change_seq = None
        while 1:
            raw = chunks.read(44)
            if not raw:
                break
            chunk_change_seq, chunk_size, chunk_hash = struct.unpack(">QL32s", raw)
            chunk_fname = '.p2p-chunk-%s-%s' % (
                change_seq_to_hex(chunk_change_seq),
                hexlify(chunk_hash),
            )
            if not os.path.exists(chunk_fname):
                log("retrieving %s" % change_seq_to_hex(chunk_change_seq))
                try:
                    with tempfile.NamedTemporaryFile(dir='.', prefix='.p2p-transfer-') as tmp:
                        received_chunk_hash = receive_chunk(
                            chunk_change_seq, str(chunk_change_seq), tmp, chunk_size, chunk_size
                        )
                        if received_chunk_hash == chunk_hash:
                            tmp.delete = False
                            os.rename(tmp.name, chunk_fname)
                        else:
                            raise SyncError("cannot fetch chunk")
                except Exception as err:
                    raise SyncError(err)
            change_seqs[chunk_change_seq] = chunk_fname, chunk_size
            if latest_change_seq is None or chunk_change_seq > latest_change_seq:
                latest_change_seq = chunk_change_seq

        new_files = set(
            chunk_fname
            for chunk_fname, chunk_size in change_seqs.itervalues()
        )

        old_files = set()
        for fname in os.listdir("."):
            m = re.match(r"^.p2p-chunk-[a-f0-9]{16}-[a-f0-9]{64}$", fname)
            if not m:
                continue
            old_files.add(fname)
        for fname in old_files - new_files:
            try:
                os.unlink(fname)
                log("removing %s" % fname)
            except:
                pass
        self._change_seqs = change_seqs
        sock.close()
        return latest_change_seq

    def link_chunk(self, change_seq, target_fname):
        info = self._change_seqs.get(change_seq)
        if info is None:
            return False
        chunk_fname, chunk_size = self._change_seqs[change_seq]
        try:
            target_inode = os.stat(target_fname).st_ino
            source_inode = os.stat(chunk_fname).st_ino
            if target_inode == source_inode:
                log('already linked %d' % change_seq)
                return True
            os.unlink(target_fname)
        except:
            pass
        log('linking %d=>%s' % (change_seq, target_fname))
        os.link(chunk_fname, target_fname)
        return True
