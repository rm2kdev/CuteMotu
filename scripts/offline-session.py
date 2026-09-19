"""Temporary per-user Mach service, synthetic backend only; no HAL installation."""
import os, pathlib, plistlib, subprocess, time, uuid, tempfile, shutil
root=pathlib.Path(__file__).resolve().parents[1]
name='org.cutemix.usbaudio.offline.'+uuid.uuid4().hex
folder=root/'build/tests';temporary=tempfile.TemporaryDirectory(prefix=name);local=pathlib.Path(temporary.name);plist=local/'service.plist';log=local/'service.log';executable=local/'cute-usb-service';shutil.copy2(root/'build/prototype/cute-usb-service',executable)
domain=f'gui/{os.getuid()}';target=domain+'/'+name
plist.write_bytes(plistlib.dumps(dict(Label=name,ProgramArguments=[str(executable),'--backend','synthetic','--no-midi','--mach-service',name],MachServices={name:True},RunAtLoad=True,ProcessType='Interactive',StandardOutPath=str(log),StandardErrorPath=str(log))))
def launch():subprocess.run(['launchctl','bootstrap',domain,str(plist)],check=True,cwd=root)
def stop():subprocess.run(['launchctl','bootout',target],check=False,cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
def wait_text(path,text,process,timeout=20):
    until=time.monotonic()+timeout
    while time.monotonic()<until:
        if text in path.read_text():return
        if process.poll() is not None:raise RuntimeError(f'harness exited {process.returncode}: '+path.read_text())
        time.sleep(.1)
    raise RuntimeError('timeout waiting for '+text+'\n'+path.read_text())
try:
    # Exercise the real service main with a failing MIDI dependency before the
    # normal synthetic session, using the same temporary Mach service identity.
    failing=root/'build/tests/service-midi-unavailable'
    if failing.exists():
        shutil.copy2(failing,executable)
        config=plistlib.loads(plist.read_bytes());config['ProgramArguments'].remove('--no-midi');plist.write_bytes(plistlib.dumps(config))
        launch();time.sleep(1)
        subprocess.run([str(folder/'service-startup-tests'),name],check=True,cwd=root)
        stop();time.sleep(.2)
        assert 'audio service continues without DIN MIDI' in log.read_text()
        shutil.copy2(root/'build/prototype/cute-usb-service',executable)
        config['ProgramArguments'].append('--no-midi');plist.write_bytes(plistlib.dumps(config))
    launch();time.sleep(1)
    subprocess.run([str(folder/'ipc-tests'),name],check=True,cwd=root)
    # Allow the old audio owner's invalidation to reach the serial service queue.
    time.sleep(.5);stop();time.sleep(.2)
    output=folder/'hal-tests.log'
    with output.open('w') as stream:
        proc=subprocess.Popen([str(folder/'hal-tests'),'--late-start'],cwd=root,env=dict(os.environ,CUTE_TEST_MACH_SERVICE=name),stdout=stream,stderr=subprocess.STDOUT)
        try:
            wait_text(output,'READY_FOR_CONNECT',proc);launch()
            wait_text(output,'READY_FOR_DISCONNECT',proc)
            stop();wait_text(output,'DISCONNECT_SILENCE_PASSED',proc)
            launch();wait_text(output,'RECONNECT_PASSED',proc)
            if proc.wait(timeout=10):raise RuntimeError(output.read_text())
        finally:
            if proc.poll() is None:proc.terminate();proc.wait(timeout=10)
    print(output.read_text())
finally:
    stop()
    if log.exists():shutil.copy2(log,folder/'synthetic-service.log')
    temporary.cleanup()
