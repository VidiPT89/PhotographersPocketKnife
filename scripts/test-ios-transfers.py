#!/usr/bin/env python3
"""Local-only fixtures for MobileTransferIntegrationTests. Run in a disposable venv.
Requires pyftpdlib, pyopenssl, paramiko, moto[server,s3]. No production accounts.
"""
from pathlib import Path
import base64, datetime, hashlib, http.server, ipaddress, json, multiprocessing, os, socket, threading, time
from urllib.parse import unquote, urlparse, parse_qs
ROOT = Path('/tmp/ppk-ios-servers')
ROOT.mkdir(exist_ok=True)
for name in ['ftp', 'ftps', 'sftp', 'webdav']:
    (ROOT/name).mkdir(exist_ok=True)

def certificate():
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'PPK local test')])
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=1))
        .not_valid_after(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=2))
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1')), x509.DNSName('localhost')]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True).sign(key, hashes.SHA256()))
    (ROOT/'ca.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (ROOT/'server.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())+cert.public_bytes(serialization.Encoding.PEM))

def ftp(tls):
    from pyftpdlib.authorizers import DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
    from pyftpdlib.servers import FTPServer
    auth = DummyAuthorizer(); auth.add_user('ppk', 'ppk-test', str(ROOT/('ftps' if tls else 'ftp')), perm='elradfmwMT')
    handler = TLS_FTPHandler if tls else FTPHandler
    handler.authorizer = auth
    if tls:
        handler.certfile = str(ROOT/'server.pem'); handler.tls_control_required = True; handler.tls_data_required = True
    FTPServer(('127.0.0.1', 12122 if tls else 12121), handler).serve_forever()

def sftp():
    import paramiko
    from paramiko import SFTPAttributes, SFTPHandle, SFTP_OK
    import io
    from cryptography.hazmat.primitives.asymmetric import ed25519
    from cryptography.hazmat.primitives import serialization
    private = ed25519.Ed25519PrivateKey.generate().private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH, serialization.NoEncryption())
    key = paramiko.Ed25519Key.from_private_key(io.StringIO(private.decode()))
    class Server(paramiko.ServerInterface):
        def check_auth_password(self, username, password): return paramiko.AUTH_SUCCESSFUL if (username,password)==('ppk','ppk-test') else paramiko.AUTH_FAILED
        def get_allowed_auths(self, username): return 'password'
        def check_channel_request(self, kind, chanid): return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    class Files(paramiko.SFTPServerInterface):
        def local(self, path):
            result = (ROOT/'sftp'/path.lstrip('/')).resolve()
            if not result.is_relative_to((ROOT/'sftp').resolve()): raise OSError('Invalid path')
            return result
        def canonicalize(self, path): return '/' + path.strip('./')
        def stat(self, path):
            try: return SFTPAttributes.from_stat(self.local(path).stat())
            except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
        lstat = stat
        def mkdir(self, path, attr):
            try: self.local(path).mkdir(); return SFTP_OK
            except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
        def open(self, path, flags, attr):
            try:
                descriptor = os.open(self.local(path), flags, 0o600)
                file = os.fdopen(descriptor, 'r+b' if flags & os.O_RDWR else ('wb' if flags & os.O_WRONLY else 'rb'))
                handle = SFTPHandle(flags); handle.readfile=file; handle.writefile=file
                return handle
            except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def client(conn):
        transport = paramiko.Transport(conn)
        transport.add_server_key(key)
        transport.set_subsystem_handler('sftp', paramiko.SFTPServer, Files)
        try:
            transport.start_server(server=Server())
            while transport.is_active(): time.sleep(0.1)
        finally: transport.close()
    listener = socket.socket(); listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); listener.bind(('127.0.0.1',12222)); listener.listen()
    while True:
        conn,_=listener.accept(); threading.Thread(target=client,args=(conn,),daemon=True).start()

class HTTP(http.server.BaseHTTPRequestHandler):
    def path_for(self):
        result = (ROOT/'webdav'/unquote(urlparse(self.path).path).lstrip('/')).resolve()
        if not result.is_relative_to((ROOT/'webdav').resolve()): raise ValueError('Invalid path')
        return result
    def authenticated(self):
        if self.headers.get('Authorization') == 'Basic '+base64.b64encode(b'ppk:ppk-test').decode(): return True
        self.send_response(401); self.send_header('WWW-Authenticate','Basic realm="PPK"'); self.end_headers(); return False
    def do_PROPFIND(self):
        if self.authenticated(): self.send_response(207); self.end_headers()
    def do_MKCOL(self):
        if not self.authenticated(): return
        path = self.path_for(); exists = path.exists(); path.mkdir(parents=True,exist_ok=True)
        self.send_response(405 if exists else 201); self.end_headers()
    def do_PUT(self):
        if not self.authenticated(): return
        path = self.path_for(); path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(self.rfile.read(int(self.headers['Content-Length'])))
        self.send_response(201); self.end_headers()
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path=='/ca.pem': body=(ROOT/'ca.pem').read_bytes()
        elif parsed.path=='/verify':
            query=parse_qs(parsed.query); kind=query['kind'][0]; name=query['path'][0]
            if kind=='s3':
                import boto3
                client=boto3.client('s3',endpoint_url='http://127.0.0.1:19100',aws_access_key_id='ppk',aws_secret_access_key='ppk-test',region_name='us-east-1')
                body=client.get_object(Bucket='ppk-bucket',Key=name.lstrip('/'))['Body'].read()
            else:
                path=(ROOT/kind/name.lstrip('/')).resolve()
                if not path.is_relative_to(ROOT.resolve()): self.send_error(400); return
                try: body=path.read_bytes()
                except OSError: self.send_error(404); return
        else: self.send_error(404); return
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)

if __name__=='__main__':
    certificate()
    from moto.server import ThreadedMotoServer
    server=ThreadedMotoServer(ip_address='127.0.0.1',port=19100,verbose=False);server.start()
    import boto3
    boto3.client('s3',endpoint_url='http://127.0.0.1:19100',aws_access_key_id='ppk',aws_secret_access_key='ppk-test',region_name='us-east-1').create_bucket(Bucket='ppk-bucket')
    processes=[multiprocessing.Process(target=ftp,args=(False,),daemon=True),multiprocessing.Process(target=ftp,args=(True,),daemon=True),multiprocessing.Process(target=sftp,daemon=True)]
    for process in processes: process.start()
    print('Ready: FTP 12121, FTPS 12122, SFTP 12222, WebDAV 18088, S3 19100',flush=True)
    try: http.server.ThreadingHTTPServer(('127.0.0.1',18088),HTTP).serve_forever()
    finally:
        for process in processes: process.terminate(); process.join()
        server.stop()
