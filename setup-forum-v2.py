"""Set up the forum on a fresh Lampy v2 install.

Called by install-v2.ps1 after the database is built. Does:
1. Patches /etc/supervisor/conf.d/lampy.conf:
   - Adds [unix_http_server], [supervisorctl], [rpcinterface:supervisor] if missing
   - Adds [program:forum] if missing
2. Creates the 'forum' PostgreSQL role with a generated password
3. Loads /opt/forum/schema.sql into the forum database
4. Generates FORUM_SECRET_KEY
5. Writes passwords to /root/.lampy-forum-secrets (600, root only)
6. Updates supervisor config with environment variables (via set-passwords.py pattern)

Idempotent: safe to re-run.
"""
import os
import re
import secrets
import sys

SUPERVISOR_CONF = "/etc/supervisor/conf.d/lampy.conf"
FORUM_DIR = "/opt/forum"
SECRETS_FILE = "/root/.lampy-forum-secrets"


def generate_password(length=24):
    """Generate a secure password with unambiguous characters."""
    chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*-_'
    return ''.join(secrets.choice(chars) for _ in range(length))


def patch_supervisor_config():
    """Add missing sections to the supervisor config."""
    with open(SUPERVISOR_CONF) as f:
        conf = f.read()
    
    changed = False
    
    # Add unix_http_server, supervisorctl, rpcinterface if missing
    if '[unix_http_server]' not in conf:
        # Insert before [supervisord]
        conf = conf.replace(
            '[supervisord]',
            '[unix_http_server]\nfile=/var/run/supervisor/supervisor.sock\nchmod=0700\n\n'
            '[rpcinterface:supervisor]\n'
            'supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface\n\n'
            '[supervisorctl]\nserverurl=unix:///var/run/supervisor/supervisor.sock\n\n'
            '[supervisord]'
        )
        changed = True
        print("Added supervisorctl sections")
    
    # Add [program:forum] if missing
    if '[program:forum]' not in conf:
        forum_prog = """
[program:forum]
command=/usr/local/bin/gunicorn -w 3 -b 127.0.0.1:8000 app:app
directory=/opt/forum
autorestart=true
stdout_logfile=/var/log/supervisor/forum.log
stderr_logfile=/var/log/supervisor/forum_err.log
"""
        conf = conf.rstrip() + "\n" + forum_prog
        changed = True
        print("Added [program:forum]")
    
    # Add [program:bible] if missing (should already be there, but be safe)
    if '[program:bible]' not in conf:
        bible_prog = """
[program:bible]
command=/usr/bin/python3 /opt/bible/website/app_v2.py
environment=BIBLE_DB="/opt/bible/bible_v2.db",PORT="5057",SCRIPT_NAME="/bible"
autorestart=true
stdout_logfile=/var/log/supervisor/bible.log
stderr_logfile=/var/log/supervisor/bible_err.log
"""
        conf = conf.rstrip() + "\n" + bible_prog
        changed = True
        print("Added [program:bible]")
    
    if changed:
        # Backup
        with open(SUPERVISOR_CONF + ".bak", "w") as f:
            f.write(open(SUPERVISOR_CONF).read())
        with open(SUPERVISOR_CONF, "w") as f:
            f.write(conf)
        print(f"Supervisor config updated: {SUPERVISOR_CONF}")
    else:
        print("Supervisor config already complete")
    
    return changed


def setup_forum_database():
    """Create forum role and load schema. Returns (db_password, secret_key)."""
    import psycopg
    
    # Generate secrets
    db_password = generate_password(24)
    secret_key = secrets.token_urlsafe(32)
    
    # Connect as postgres superuser
    conn = psycopg.connect("host=127.0.0.1 port=5432 dbname=postgres user=postgres")
    conn.autocommit = True
    cur = conn.cursor()
    
    # Create role if not exists
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname='forum'")
    if not cur.fetchone():
        # Use parameterized query for password to avoid injection
        cur.execute("CREATE ROLE forum WITH LOGIN PASSWORD %s", (db_password,))
        print("Created role 'forum'")
    else:
        # Update password
        cur.execute("ALTER ROLE forum WITH PASSWORD %s", (db_password,))
        print("Updated password for role 'forum'")
    
    # Grant database privileges
    cur.execute("GRANT ALL PRIVILEGES ON DATABASE forum TO forum")
    
    # Grant schema permissions
    conn2 = psycopg.connect("host=127.0.0.1 port=5432 dbname=forum user=postgres")
    conn2.autocommit = True
    cur2 = conn2.cursor()
    cur2.execute("GRANT CREATE ON SCHEMA public TO forum")
    cur2.execute("GRANT ALL ON SCHEMA public TO forum")
    conn2.close()
    print("Granted schema permissions")
    
    conn.close()
    
    # Load schema as forum user
    conn = psycopg.connect(
        f"host=127.0.0.1 port=5432 dbname=forum user=forum password={db_password}"
    )
    conn.autocommit = True
    cur = conn.cursor()
    
    # Check if tables already exist
    cur.execute("SELECT COUNT(*) FROM pg_tables WHERE schemaname='public'")
    table_count = cur.fetchone()[0]
    
    if table_count == 0:
        schema_path = os.path.join(FORUM_DIR, "schema.sql")
        with open(schema_path) as f:
            schema = f.read()
        cur.execute(schema)
        print("Loaded forum schema")
    else:
        print(f"Forum schema already loaded ({table_count} tables)")
    
    conn.close()
    
    return db_password, secret_key


def update_supervisor_env(db_password, secret_key):
    """Add environment variables to the forum program section."""
    with open(SUPERVISOR_CONF) as f:
        conf = f.read()
    
    def _quote(v):
        return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')
    
    # Find [program:forum] section and update/add environment line
    pattern = r'(\[program:forum\].*?)(?=\n\[)'
    match = re.search(pattern, conf, flags=re.S)
    if not match:
        # Try end of file
        pattern = r'(\[program:forum\].*)$'
        match = re.search(pattern, conf, flags=re.S)
    
    if match:
        section = match.group(1)
        # Remove existing environment lines for these keys
        lines = [l for l in section.split('\n')
                 if not re.match(r'^environment=(FORUM_DB_PASS|FORUM_SECRET_KEY)=', l)]
        # Add new environment line after [program:forum]
        env_line = f'environment=FORUM_DB_PASS={_quote(db_password)},FORUM_SECRET_KEY={_quote(secret_key)}'
        lines.insert(1, env_line)
        new_section = '\n'.join(lines)
        conf = conf[:match.start(1)] + new_section + conf[match.end(1):]
        
        with open(SUPERVISOR_CONF, "w") as f:
            f.write(conf)
        print("Updated forum environment variables in supervisor config")
    else:
        print("ERROR: [program:forum] section not found!", file=sys.stderr)
        sys.exit(1)


def save_secrets(db_password, secret_key):
    """Save secrets to locked file."""
    with open(SECRETS_FILE, "w") as f:
        f.write(f"FORUM_DB_PASS={db_password}\n")
        f.write(f"FORUM_SECRET_KEY={secret_key}\n")
    os.chmod(SECRETS_FILE, 0o600)
    print(f"Secrets saved to {SECRETS_FILE} (600)")


def main():
    print("=== Setting up forum ===")
    
    # 1. Patch supervisor config
    patch_supervisor_config()
    
    # 2. Setup database (requires postgres running)
    try:
        db_password, secret_key = setup_forum_database()
    except Exception as e:
        print(f"Database setup failed: {e}", file=sys.stderr)
        print("Is PostgreSQL running?", file=sys.stderr)
        sys.exit(1)
    
    # 3. Update supervisor config with secrets
    update_supervisor_env(db_password, secret_key)
    
    # 4. Save secrets
    save_secrets(db_password, secret_key)
    
    print("=== Forum setup complete ===")
    print("NOTE: Restart supervisord for changes to take effect:")
    print("  supervisorctl -c /etc/supervisor/conf.d/lampy.conf reload")


if __name__ == "__main__":
    main()
