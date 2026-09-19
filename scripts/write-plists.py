import pathlib, plistlib, sys
base=pathlib.Path(__file__).resolve().parents[1]/'build/prototype'
def write(path,data):
    (base/path).write_bytes(plistlib.dumps(data))
common=dict(CFBundleShortVersionString='0.1.6',CFBundleVersion='7',LSMinimumSystemVersion='13.0')
if '--app-only' not in sys.argv:
    write(pathlib.Path('CuteMixUSB.driver/Contents/Info.plist'),dict(common,CFBundleIdentifier='org.cutemix.usbaudio.hal',CFBundleName='Cute Mix USB Audio Prototype',CFBundleExecutable='CuteMixUSB',CFBundlePackageType='BNDL',CFPlugInDynamicRegistration=False,CFPlugInFactories={'9BE6C87E-11D6-453F-9C88-FCF951C55301':'CuteMixFactory'},CFPlugInTypes={'443ABAB8-E7B3-491A-B985-BEB9187030DB':['9BE6C87E-11D6-453F-9C88-FCF951C55301']},AudioServerPlugIn_MachServices=['org.cutemix.usbaudio.service']))
write(pathlib.Path('Cute Mix USB.app/Contents/Info.plist'),dict(common,CFBundleShortVersionString='0.3.0',CFBundleVersion='10',CFBundleIdentifier='org.cutemix.usbaudio.app',CFBundleName='Cute Mix USB',CFBundleDisplayName='Cute Mix USB',CFBundleExecutable='Cute Mix USB',CFBundlePackageType='APPL',NSHighResolutionCapable=True,NSPrincipalClass='NSApplication',NSMicrophoneUsageDescription='Cute Mix uses your selected 828x audio inputs for the tuner, spectrum, X–Y, phase, oscilloscope and loudness meters. Audio is processed locally and is never recorded or uploaded.'))
