'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const run = promisify(execFile);

// A fresh ACL, rather than merely disabling inheritance, removes any old explicit grants.
async function restrictToCurrentUser(target, directory = false) {
  if (process.platform !== 'win32') return fs.chmod(target, directory ? 0o700 : 0o600);
  const literal = "'" + target.replace(/'/g, "''") + "'";
  const script = [
    "$ErrorActionPreference='Stop'",
    '$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User',
    `$acl=New-Object System.Security.AccessControl.${directory ? 'DirectorySecurity' : 'FileSecurity'}`,
    '$acl.SetAccessRuleProtection($true,$false)',
    directory
      ? '$rule=New-Object System.Security.AccessControl.FileSystemAccessRule($sid,"FullControl","ContainerInherit,ObjectInherit","None","Allow")'
      : '$rule=New-Object System.Security.AccessControl.FileSystemAccessRule($sid,"FullControl","Allow")',
    '$acl.AddAccessRule($rule)', `[System.IO.${directory ? 'Directory' : 'File'}]::SetAccessControl(${literal},$acl)`,
  ].join(';');
  await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], { windowsHide: true, timeout: 15000 });
}

async function atomicJSON(file, value) {
  const temporary = path.join(path.dirname(file), `.${path.basename(file)}-${process.pid}-${require('node:crypto').randomUUID()}.tmp`);
  try {
    await fs.writeFile(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
    await restrictToCurrentUser(temporary);
    await fs.rename(temporary, file);
  } finally { await fs.rm(temporary, { force: true }).catch(() => {}); }
}

// libuv's Windows pipes use the process default ACL and do not reject SMB clients.
// PipeSecurity applies to the named pipe object shared by its instances. Denying
// NETWORK blocks remote logons even when they present this user's credentials.
async function restrictNamedPipe(address) {
  if (process.platform !== 'win32') return;
  const prefix = '\\\\.\\pipe\\';
  if (!address.startsWith(prefix)) throw new Error('MCP 只允许本机命名管道');
  const literal = "'" + address.slice(prefix.length).replace(/'/g, "''") + "'";
  const script = [
    "$ErrorActionPreference='Stop'",
    '$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User',
    '$rights=[System.IO.Pipes.PipeAccessRights]::ReadWrite -bor [System.IO.Pipes.PipeAccessRights]::ReadPermissions -bor [System.IO.Pipes.PipeAccessRights]::ChangePermissions',
    `$pipe=[System.IO.Pipes.NamedPipeClientStream]::new('.',${literal},$rights,[System.IO.Pipes.PipeOptions]::Asynchronous,[System.Security.Principal.TokenImpersonationLevel]::None,[System.IO.HandleInheritability]::None)`,
    'try{$pipe.Connect(5000)',
    '$acl=[System.IO.Pipes.PipeSecurity]::new()', '$acl.SetAccessRuleProtection($true,$false)',
    '$network=[System.Security.Principal.SecurityIdentifier]::new("S-1-5-2")',
    '$acl.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new($network,[System.IO.Pipes.PipeAccessRights]::FullControl,[System.Security.AccessControl.AccessControlType]::Deny))',
    '$acl.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new($sid,[System.IO.Pipes.PipeAccessRights]::FullControl,[System.Security.AccessControl.AccessControlType]::Allow))',
    '$pipe.SetAccessControl($acl)}finally{$pipe.Dispose()}',
  ].join(';');
  await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], { windowsHide: true, timeout: 15000 });
}

module.exports = { restrictToCurrentUser, restrictNamedPipe, atomicJSON };
