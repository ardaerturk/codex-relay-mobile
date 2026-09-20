"""Create a private pairing credential. Never overwrite or print an existing one."""
import os
from pathlib import Path
import secrets

state = Path(os.environ.get('RELAY_STATE_DIR', str(Path.home() / '.local/state/relay')))
state.mkdir(mode=0o700, parents=True, exist_ok=True)
path = Path(os.environ.get('RELAY_TOKEN_FILE', str(state / 'pairing-token')))
try:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    raise SystemExit('A pairing file already exists. It was left unchanged.')
with os.fdopen(fd, 'w') as stream:
    stream.write(secrets.token_urlsafe(48) + '\n')
print('Created a private pairing file. Its contents were not printed.')
