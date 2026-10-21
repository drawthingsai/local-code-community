#!/usr/bin/env python3
"""Build a temporary Catalyst harness exercising the shipping UIKit capture implementation."""
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
source=Path(__file__).resolve().parent
repo=source.parents[2]
app=Path(sys.argv[1]).resolve()
binary=app/'Contents/MacOS/UIKitCapture'
binary.parent.mkdir(parents=True,exist_ok=True)
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-O','-target',f'{platform.machine()}-apple-ios15.4-macabi','-sdk',sdk,'-Fsystem',sdk+'/System/iOSSupport/System/Library/Frameworks','-L',sdk+'/System/iOSSupport/usr/lib/swift','-Xlinker','-rpath','-Xlinker','/System/iOSSupport/usr/lib/swift','-module-cache-path','/tmp/HyperFramesCapture-module-cache',str(source/'UIKitCaptureMain.swift'),*map(str,(repo/'Libraries/HTMLVideoExporter/Sources').glob('*.swift')),'-o',str(binary)],check=True)
with (app/'Contents/Info.plist').open('wb') as file:
 plistlib.dump({'CFBundleName':'HyperFrames Capture Test','CFBundleIdentifier':'com.liuliu.hyperframes-capture-test','CFBundleExecutable':binary.name,'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundleSupportedPlatforms':['MacOSX'],'UIDeviceFamily':[2],'LSMinimumSystemVersion':'12.3','UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False}},file)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print(binary)
