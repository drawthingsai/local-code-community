#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#define STATIC_INLINE_PYTHON_UIKIT_APP 1
#else
#define STATIC_INLINE_PYTHON_UIKIT_APP 0
#endif

#import "ios_system.h"

#include <limits.h>
#include <pthread.h>
#include <unistd.h>

static NSString *StaticInlinePythonShellQuote(NSString *value) {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

static void StaticInlinePythonConfigurePythonEnvironment(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *workspace = NSProcessInfo.processInfo.environment[@"BUILD_WORKSPACE_DIRECTORY"];
    if (workspace.length > 0) {
        [candidates addObject:[workspace stringByAppendingPathComponent:@"Vendors/PythonIOS/ResourcesMacOS/Library"]];
    }

    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)) != NULL) {
        [candidates addObject:[@(cwd) stringByAppendingPathComponent:@"Vendors/PythonIOS/ResourcesMacOS/Library"]];
    }

    NSString *bundleLibrary = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Library"];
    if (bundleLibrary.length > 0) {
        [candidates addObject:bundleLibrary];
    }

    for (NSString *pythonHome in candidates) {
        BOOL isDirectory = NO;
        NSString *stdlibPath = [pythonHome stringByAppendingPathComponent:@"lib/python3.14"];
        if ([NSFileManager.defaultManager fileExistsAtPath:stdlibPath isDirectory:&isDirectory] && isDirectory) {
            setenv("PYTHONHOME", pythonHome.UTF8String, 1);
            setenv("PYTHONUSERBASE", pythonHome.UTF8String, 1);
            NSString *cachePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"StaticInlinePython/pycache"];
            [NSFileManager.defaultManager createDirectoryAtPath:cachePath withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("PYTHONPYCACHEPREFIX", cachePath.UTF8String, 1);
            NSString *pipCachePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"StaticInlinePython/pip-cache"];
            [NSFileManager.defaultManager createDirectoryAtPath:pipCachePath withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("PIP_CACHE_DIR", pipCachePath.UTF8String, 1);
            setenv("PIP_DISABLE_PIP_VERSION_CHECK", "1", 1);
            NSString *certifiCACert = [pythonHome stringByAppendingPathComponent:@"lib/python3.14/site-packages/certifi/cacert.pem"];
            BOOL certifiCACertIsDirectory = NO;
            if ([NSFileManager.defaultManager fileExistsAtPath:certifiCACert isDirectory:&certifiCACertIsDirectory] &&
                !certifiCACertIsDirectory) {
                setenv("SSL_CERT_FILE", certifiCACert.UTF8String, 1);
            }
            return;
        }
    }
}

static int StaticInlinePythonWriteFile(NSString *path, NSString *contents) {
    NSError *error = nil;
    if (![contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        fprintf(stderr, "[StaticInlinePython] failed writing %s: %s\n", path.UTF8String, error.localizedDescription.UTF8String);
        return 1;
    }
    return 0;
}

static NSString *StaticInlinePythonReadFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) {
        return @"";
    }
    NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return contents ?: @"";
}

static int StaticInlinePythonCheckFragments(NSString *streamName, NSString *text, NSArray<NSString *> *expectedFragments) {
    for (NSString *fragment in expectedFragments) {
        if ([text rangeOfString:fragment].location == NSNotFound) {
            fprintf(stderr, "[StaticInlinePython] missing expected %s fragment: %s\n", streamName.UTF8String, fragment.UTF8String);
            return 1;
        }
    }
    return 0;
}

static int StaticInlinePythonRunCommand(
    NSString *command,
    int expectedStatus,
    NSArray<NSString *> *expectedStdoutFragments,
    NSArray<NSString *> *expectedStderrFragments,
    NSString *directory,
    NSUInteger index)
{
    NSString *stdoutPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"command-%03lu.out", (unsigned long)index]];
    NSString *stderrPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"command-%03lu.err", (unsigned long)index]];
    NSString *wrappedCommand = [NSString stringWithFormat:@"%@ > %@ 2> %@", command, StaticInlinePythonShellQuote(stdoutPath), StaticInlinePythonShellQuote(stderrPath)];
    fprintf(stderr, "\n[StaticInlinePython] $ %s\n", command.UTF8String);
    fflush(stderr);
    int status = ios_system_osh(wrappedCommand.UTF8String);
    NSString *stdoutText = StaticInlinePythonReadFile(stdoutPath);
    NSString *stderrText = StaticInlinePythonReadFile(stderrPath);
    if (stdoutText.length > 0) {
        fputs(stdoutText.UTF8String, stdout);
        if (![stdoutText hasSuffix:@"\n"]) {
            fputc('\n', stdout);
        }
        fflush(stdout);
    }
    if (stderrText.length > 0) {
        fputs(stderrText.UTF8String, stderr);
        if (![stderrText hasSuffix:@"\n"]) {
            fputc('\n', stderr);
        }
        fflush(stderr);
    }
    fprintf(stderr, "[StaticInlinePython] status=%d\n", status);
    fflush(stderr);
    if (status != expectedStatus) {
        fprintf(stderr, "[StaticInlinePython] expected status=%d\n", expectedStatus);
        return 1;
    }
    if (StaticInlinePythonCheckFragments(@"stdout", stdoutText, expectedStdoutFragments) != 0) {
        return 1;
    }
    if (StaticInlinePythonCheckFragments(@"stderr", stderrText, expectedStderrFragments) != 0) {
        return 1;
    }
    return 0;
}

static int StaticInlinePythonCreateDirectory(NSString *path) {
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "[StaticInlinePython] failed creating %s: %s\n", path.UTF8String, error.localizedDescription.UTF8String);
        return 1;
    }
    return 0;
}

static int StaticInlinePythonRunSuite(void) {
    ios_setStreams(stdin, stdout, stderr);
    initializeEnvironment();
    StaticInlinePythonConfigurePythonEnvironment();

    NSString *ytDlpTestPath = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"py"];
    if (ytDlpTestPath == nil) {
        NSString *workspace = NSProcessInfo.processInfo.environment[@"BUILD_WORKSPACE_DIRECTORY"]
            ?: NSFileManager.defaultManager.currentDirectoryPath;
        ytDlpTestPath = [workspace stringByAppendingPathComponent:@"Vendors/PythonIOS/YTDLP/Tests/embedded.py"];
    }

    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"StaticInlinePython-%d", getpid()]];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "[StaticInlinePython] failed creating %s: %s\n", directory.UTF8String, error.localizedDescription.UTF8String);
        return 1;
    }

    NSString *scriptPath = [directory stringByAppendingPathComponent:@"script.py"];
    NSString *recursivePath = [directory stringByAppendingPathComponent:@"recursive.py"];
    NSString *recursiveFailurePath = [directory stringByAppendingPathComponent:@"recursive_failure.py"];
    NSString *recursiveIsolationPath = [directory stringByAppendingPathComponent:@"recursive_isolation.py"];
    NSString *hfXetRecursivePath = [directory stringByAppendingPathComponent:@"hf_xet_recursive.py"];
    NSString *safetensorsRecursivePath = [directory stringByAppendingPathComponent:@"safetensors_recursive.py"];
    NSString *regexRecursivePath = [directory stringByAppendingPathComponent:@"regex_recursive.py"];
    NSString *tokenizersRecursivePath = [directory stringByAppendingPathComponent:@"tokenizers_recursive.py"];
    NSString *sentencepieceRecursivePath = [directory stringByAppendingPathComponent:@"sentencepiece_recursive.py"];
    NSString *cairosvgTestPath = [directory stringByAppendingPathComponent:@"cairosvg_test.py"];
    NSString *cairosvgSubinterpreterPath = [directory stringByAppendingPathComponent:@"cairosvg_subinterpreter.py"];
    NSString *pillowCodecsTestPath = [directory stringByAppendingPathComponent:@"pillow_codecs_test.py"];
    NSString *stdinPath = [directory stringByAppendingPathComponent:@"stdin.py"];
    NSString *stdinArgumentsPath = [directory stringByAppendingPathComponent:@"stdin_arguments.py"];
    NSString *jsonPath = [directory stringByAppendingPathComponent:@"input.json"];
    NSString *systemDocumentsPath = [directory stringByAppendingPathComponent:@"system-documents"];
    NSString *systemLibraryPath = [directory stringByAppendingPathComponent:@"system-library"];
    NSString *systemCachesPath = [directory stringByAppendingPathComponent:@"system-caches"];
    NSString *projectAPath = [directory stringByAppendingPathComponent:@"project-a"];
    NSString *projectBPath = [directory stringByAppendingPathComponent:@"project-b"];
    NSString *projectASitePackagesPath = [projectAPath stringByAppendingPathComponent:@".localc/python/lib/python3.14/site-packages"];
    NSString *projectBSitePackagesPath = [projectBPath stringByAppendingPathComponent:@".localc/python/lib/python3.14/site-packages"];
    NSString *latePackagePath = [projectASitePackagesPath stringByAppendingPathComponent:@"late_pkg"];
    NSString *refreshPackagePath = [projectASitePackagesPath stringByAppendingPathComponent:@"refresh_pkg"];
    NSString *pipFixtureBuilderPath = [directory stringByAppendingPathComponent:@"build_pip_fixture.py"];
    NSString *pipFixtureDirectory = [directory stringByAppendingPathComponent:@"pip-fixture"];
    NSString *pipFixtureDistInfoPath = [pipFixtureDirectory stringByAppendingPathComponent:@"ios_pip_probe-1.0.dist-info"];
    NSString *pipFixtureWheelPath = [directory stringByAppendingPathComponent:@"ios_pip_probe-1.0-py3-none-any.whl"];
    NSString *huggingfaceHubFixtureDirectory = [directory stringByAppendingPathComponent:@"huggingface-hub-fixture"];
    NSString *huggingfaceHubFixturePackagePath = [huggingfaceHubFixtureDirectory stringByAppendingPathComponent:@"huggingface_hub"];
    NSString *huggingfaceHubFixtureDistInfoPath = [huggingfaceHubFixtureDirectory stringByAppendingPathComponent:@"huggingface_hub-1.5.0.dist-info"];
    NSString *huggingfaceHubFixtureWheelPath = [directory stringByAppendingPathComponent:@"huggingface_hub-1.5.0-py3-none-any.whl"];

    int status = 0;
    status |= StaticInlinePythonCreateDirectory(systemDocumentsPath);
    status |= StaticInlinePythonCreateDirectory(systemLibraryPath);
    status |= StaticInlinePythonCreateDirectory(systemCachesPath);
    status |= StaticInlinePythonCreateDirectory(projectASitePackagesPath);
    status |= StaticInlinePythonCreateDirectory(projectBSitePackagesPath);
    status |= StaticInlinePythonCreateDirectory(pipFixtureDistInfoPath);
    status |= StaticInlinePythonCreateDirectory(huggingfaceHubFixturePackagePath);
    status |= StaticInlinePythonCreateDirectory(huggingfaceHubFixtureDistInfoPath);
    status |= StaticInlinePythonWriteFile(scriptPath, @"import sys\nprint('script ok', sys.argv[1:])\n");
    status |= StaticInlinePythonWriteFile(
        recursivePath,
        @"import os\nprint('outer before')\nstatus = os.system(\"python -c \\\"print('inner ok')\\\"\")\nprint('outer after', status)\nraise SystemExit(status)\n");
    status |= StaticInlinePythonWriteFile(
        recursiveFailurePath,
        @"import os\nstatus = os.system(\"python -c \\\"raise SystemExit(5)\\\"\")\nprint('recursive failure status', status)\nraise SystemExit(0 if status == 5 else 1)\n");
    status |= StaticInlinePythonWriteFile(
        recursiveIsolationPath,
        @"import builtins, os\nbuiltins._ios_outer_marker = 1\nstatus = os.system(\"python -c \\\"import builtins; print('recursive marker exists', hasattr(builtins, '_ios_outer_marker'))\\\"\")\nraise SystemExit(status)\n");
    status |= StaticInlinePythonWriteFile(
        hfXetRecursivePath,
        @"import hf_xet, os\nsession = hf_xet.XetSession()\nstatus = os.system(\"python -c \\\"import hf_xet\\\"\")\nsession.sigint_abort()\nprint('hf_xet recursive status', status)\nraise SystemExit(0 if status == 1 else 1)\n");
    status |= StaticInlinePythonWriteFile(
        safetensorsRecursivePath,
        @"import os, safetensors\nstatus = os.system(\"python -c \\\"import safetensors\\\"\")\nprint('safetensors recursive status', status)\nraise SystemExit(0 if status == 1 else 1)\n");
    status |= StaticInlinePythonWriteFile(
        regexRecursivePath,
        @"import os, regex\nstatus = os.system(\"python -c \\\"import regex\\\"\")\nprint('regex recursive status', status)\nraise SystemExit(0 if status == 1 else 1)\n");
    status |= StaticInlinePythonWriteFile(
        tokenizersRecursivePath,
        @"import os, tokenizers\nstatus = os.system(\"python -c \\\"import tokenizers\\\"\")\nprint('tokenizers recursive status', status)\nraise SystemExit(0 if status == 1 else 1)\n");
    status |= StaticInlinePythonWriteFile(
        sentencepieceRecursivePath,
        @"import os, sentencepiece\nstatus = os.system(\"python -c \\\"import sentencepiece\\\"\")\nprint('sentencepiece recursive status', status)\nraise SystemExit(0 if status == 1 else 1)\n");
    status |= StaticInlinePythonWriteFile(
        cairosvgTestPath,
        @"import base64\n"
        @"import gc\n"
        @"import importlib.metadata as metadata\n"
        @"import io\n"
        @"from pathlib import Path\n"
        @"\n"
        @"import cairocffi\n"
        @"import cairosvg\n"
        @"from PIL import Image\n"
        @"\n"
        @"assert __import__('_cffi_backend').__spec__.origin == 'built-in'\n"
        @"assert cairocffi.ffi.__class__.__module__ == '_cffi_backend'\n"
        @"assert metadata.version('cffi') == '2.1.1'\n"
        @"assert metadata.version('cairosvg') == '2.9.1'\n"
        @"assert cairocffi.cairo_version_string() == '1.18.6'\n"
        @"svg = b'''<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"48\">\n"
        @"<style>.box { fill: #ff0000; }</style>\n"
        @"<path class=\"box\" d=\"M0 0H32V24H0Z\"/>\n"
        @"</svg>'''\n"
        @"image = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg))).convert('RGBA')\n"
        @"assert image.size == (64, 48)\n"
        @"assert image.getpixel((8, 8)) == (255, 0, 0, 255)\n"
        @"assert image.getpixel((50, 30)) == (0, 0, 0, 0)\n"
        @"scaled = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg, output_width=128)))\n"
        @"assert scaled.size == (128, 96)\n"
        @"gradient = b'''<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"16\">\n"
        @"<defs><linearGradient id=\"g\"><stop stop-color=\"red\"/><stop offset=\"1\" stop-color=\"blue\"/></linearGradient></defs>\n"
        @"<rect width=\"64\" height=\"16\" fill=\"url(#g)\"/></svg>'''\n"
        @"g = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=gradient))).convert('RGB')\n"
        @"assert g.getpixel((4, 8))[0] > 220 and g.getpixel((59, 8))[2] > 220\n"
        @"text = b'''<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"32\">\n"
        @"<text x=\"2\" y=\"25\" font-family=\"sans-serif\" font-size=\"20\">Hello</text></svg>'''\n"
        @"t = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=text))).convert('RGBA')\n"
        @"assert t.getchannel('A').getbbox() is not None\n"
        @"png = io.BytesIO()\n"
        @"Image.new('RGB', (4, 4), (0, 255, 0)).save(png, format='PNG')\n"
        @"embedded = ('<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"4\" height=\"4\">'\n"
        @"            '<image width=\"4\" height=\"4\" xlink:href=\"data:image/png;base64,'\n"
        @"            + base64.b64encode(png.getvalue()).decode() + '\"/></svg>').encode()\n"
        @"e = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=embedded))).convert('RGBA')\n"
        @"assert e.getpixel((2, 2)) == (0, 255, 0, 255)\n"
        @"Path('cairo-input.svg').write_bytes(svg)\n"
        @"cairosvg.svg2png(url='cairo-input.svg', write_to='cairo-file.png')\n"
        @"assert Image.open('cairo-file.png').size == (64, 48)\n"
        @"for convert, signature in ((cairosvg.svg2pdf, b'%PDF-'), (cairosvg.svg2ps, b'%!PS'), (cairosvg.svg2svg, b'<?xml')):\n"
        @"    stream = io.BytesIO()\n"
        @"    convert(bytestring=svg, write_to=stream)\n"
        @"    assert stream.getvalue().startswith(signature)\n"
        @"try:\n"
        @"    cairosvg.svg2png(bytestring=b'<svg')\n"
        @"except Exception:\n"
        @"    pass\n"
        @"else:\n"
        @"    raise AssertionError('malformed SVG accepted')\n"
        @"for _ in range(20):\n"
        @"    cairosvg.svg2pdf(bytestring=text)\n"
        @"    cairosvg.svg2png(bytestring=embedded)\n"
        @"surface = cairocffi.ImageSurface(cairocffi.FORMAT_ARGB32, 2, 2)\n"
        @"surface.set_mime_data('image/png', png.getvalue())\n"
        @"assert bytes(surface.get_mime_data('image/png')) == png.getvalue()\n"
        @"surface.set_mime_data('image/png', None)\n"
        @"del surface\n"
        @"gc.collect()\n"
        @"assert not cairocffi.surfaces.KeepAlive.instances\n"
        @"print('cairosvg rendering suite ok')\n");
    status |= StaticInlinePythonWriteFile(
        cairosvgSubinterpreterPath,
        @"import _interpreters, cairosvg\n"
        @"interp = _interpreters.create()\n"
        @"try:\n"
        @"    error = _interpreters.run_string(interp, 'import cairosvg')\n"
        @"    assert error is not None\n"
        @"    assert error.type.__name__ == 'ImportError', error\n"
        @"    assert 'does not support loading in subinterpreters' in error.formatted, error\n"
        @"    print('cairosvg subinterpreter rejection ok')\n"
        @"finally:\n"
        @"    _interpreters.destroy(interp)\n");
    status |= StaticInlinePythonWriteFile(
        pillowCodecsTestPath,
        @"import base64\n"
        @"import importlib.metadata as metadata\n"
        @"import io\n"
        @"\n"
        @"import cairosvg\n"
        @"import matplotlib\n"
        @"from PIL import Image, ImageChops, ImageDraw, ImageFont, features\n"
        @"\n"
        @"matplotlib.use('Agg')\n"
        @"from matplotlib import pyplot as plt\n"
        @"\n"
        @"assert metadata.version('pillow') == '12.3.0'\n"
        @"assert features.version('libjpeg_turbo') == '3.2.0'\n"
        @"assert features.version('freetype2') == '2.14.3'\n"
        @"assert features.version('raqm') == '0.10.5'\n"
        @"source = Image.linear_gradient('L').resize((64, 48)).convert('RGB')\n"
        @"jpeg = io.BytesIO()\n"
        @"source.save(jpeg, format='JPEG', quality=90, progressive=True)\n"
        @"decoded = Image.open(io.BytesIO(jpeg.getvalue()))\n"
        @"assert decoded.format == 'JPEG' and decoded.size == (64, 48)\n"
        @"assert ImageChops.difference(decoded.convert('L'), source.convert('L')).getextrema()[1] < 16\n"
        @"default = ImageFont.load_default(size=24)\n"
        @"assert isinstance(default, ImageFont.FreeTypeFont)\n"
        @"# load_default pins basic layout; truetype selects Raqm when available.\n"
        @"font = ImageFont.truetype(io.BytesIO(default.font_bytes), 24)\n"
        @"assert font.layout_engine == ImageFont.Layout.RAQM\n"
        @"horizontal = Image.new('L', (200, 200))\n"
        @"ImageDraw.Draw(horizontal).text((20, 20), 'Hello', font=font, fill=255)\n"
        @"left, top, right, bottom = horizontal.getbbox()\n"
        @"assert right - left > bottom - top\n"
        @"vertical = Image.new('L', (200, 200))\n"
        @"ImageDraw.Draw(vertical).text((20, 20), 'Hello', font=font, fill=255, direction='ttb')\n"
        @"left, top, right, bottom = vertical.getbbox()\n"
        @"assert bottom - top > right - left\n"
        @"assert font.getlength('AVAWAT', features=['-kern']) > font.getlength('AVAWAT')\n"
        @"swatch = io.BytesIO()\n"
        @"Image.new('RGB', (8, 8), (0, 200, 0)).save(swatch, format='JPEG', quality=95)\n"
        @"embedded = ('<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"8\" height=\"8\">'\n"
        @"            '<image width=\"8\" height=\"8\" xlink:href=\"data:image/jpeg;base64,'\n"
        @"            + base64.b64encode(swatch.getvalue()).decode() + '\"/></svg>').encode()\n"
        @"red, green, blue, alpha = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=embedded))).convert('RGBA').getpixel((4, 4))\n"
        @"assert red < 16 and green > 184 and blue < 16 and alpha == 255\n"
        @"figure = plt.figure(figsize=(1, 1), dpi=32)\n"
        @"plt.plot([0, 1], [1, 0])\n"
        @"chart = io.BytesIO()\n"
        @"figure.savefig(chart, format='jpg')\n"
        @"plt.close(figure)\n"
        @"assert Image.open(io.BytesIO(chart.getvalue())).format == 'JPEG'\n"
        @"print('pillow codec suite ok')\n");
    status |= StaticInlinePythonWriteFile(stdinPath, @"print('stdin ok')\n");
    status |= StaticInlinePythonWriteFile(
        stdinArgumentsPath,
        @"import sys\nprint('stdin argv', sys.argv)\n");
    status |= StaticInlinePythonWriteFile(jsonPath, @"{\"hello\": [\"python\", 314]}\n");
    status |= StaticInlinePythonWriteFile([projectASitePackagesPath stringByAppendingPathComponent:@"local_marker.py"], @"VALUE = 'project-a'\n");
    status |= StaticInlinePythonWriteFile([projectBSitePackagesPath stringByAppendingPathComponent:@"local_marker.py"], @"VALUE = 'project-b'\n");
    status |= StaticInlinePythonWriteFile(
        pipFixtureBuilderPath,
        @"import pathlib, sys, zipfile\nroot = pathlib.Path(sys.argv[1])\nwith zipfile.ZipFile(sys.argv[2], 'w') as wheel:\n    for path in root.rglob('*'):\n        if path.is_file():\n            wheel.write(path, path.relative_to(root))\nprint('pip fixture wheel created')\n");
    status |= StaticInlinePythonWriteFile([pipFixtureDirectory stringByAppendingPathComponent:@"ios_pip_probe.py"], @"VALUE = 'project-local'\n");
    status |= StaticInlinePythonWriteFile(
        [pipFixtureDistInfoPath stringByAppendingPathComponent:@"METADATA"],
        @"Metadata-Version: 2.1\nName: ios-pip-probe\nVersion: 1.0\nRequires-Dist: numpy>=2\nRequires-Dist: hf-xet>=1.5.2\nRequires-Dist: safetensors>=0.8.0\nRequires-Dist: regex>=2025.10.22\nRequires-Dist: tokenizers>=0.22.0,<=0.23.0\nRequires-Dist: sentencepiece>=0.2.2,<0.3\n");
    status |= StaticInlinePythonWriteFile(
        [pipFixtureDistInfoPath stringByAppendingPathComponent:@"WHEEL"],
        @"Wheel-Version: 1.0\nGenerator: ios-system-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n");
    status |= StaticInlinePythonWriteFile(
        [pipFixtureDistInfoPath stringByAppendingPathComponent:@"RECORD"],
        @"ios_pip_probe.py,,\nios_pip_probe-1.0.dist-info/METADATA,,\nios_pip_probe-1.0.dist-info/WHEEL,,\nios_pip_probe-1.0.dist-info/RECORD,,\n");
    status |= StaticInlinePythonWriteFile(
        [huggingfaceHubFixturePackagePath stringByAppendingPathComponent:@"__init__.py"],
        @"__version__ = '1.5.0'\n");
    status |= StaticInlinePythonWriteFile(
        [huggingfaceHubFixtureDistInfoPath stringByAppendingPathComponent:@"METADATA"],
        @"Metadata-Version: 2.1\nName: huggingface-hub\nVersion: 1.5.0\n");
    status |= StaticInlinePythonWriteFile(
        [huggingfaceHubFixtureDistInfoPath stringByAppendingPathComponent:@"WHEEL"],
        @"Wheel-Version: 1.0\nGenerator: ios-system-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n");
    status |= StaticInlinePythonWriteFile(
        [huggingfaceHubFixtureDistInfoPath stringByAppendingPathComponent:@"RECORD"],
        @"huggingface_hub/__init__.py,,\nhuggingface_hub-1.5.0.dist-info/METADATA,,\nhuggingface_hub-1.5.0.dist-info/WHEEL,,\nhuggingface_hub-1.5.0.dist-info/RECORD,,\n");
    if (status != 0) {
        return status;
    }

    if (ios_setSystemPaths(
            [NSURL fileURLWithPath:systemDocumentsPath isDirectory:YES],
            [NSURL fileURLWithPath:systemLibraryPath isDirectory:YES],
            [NSURL fileURLWithPath:systemCachesPath isDirectory:YES],
            [NSURL fileURLWithPath:directory isDirectory:YES],
            [NSURL fileURLWithPath:projectAPath isDirectory:YES],
            [NSURL fileURLWithPath:directory isDirectory:YES]) == 0) {
        fprintf(stderr, "[StaticInlinePython] failed setting project-a system paths\n");
        return 1;
    }
    ios_setDirectoryURL([NSURL fileURLWithPath:projectAPath isDirectory:YES]);

    NSArray<NSArray *> *commands = @[
        @[@"which python", @0, @[@"/usr/bin/python"], @[]],
        @[@"which python3", @0, @[@"/usr/bin/python3"], @[]],
        @[@"which python3.14", @0, @[@"/usr/bin/python3.14"], @[]],
        @[@"which pip", @0, @[@"/usr/bin/pip"], @[]],
        @[@"which pip3", @0, @[@"/usr/bin/pip3"], @[]],
        @[@"which pip3.14", @0, @[@"/usr/bin/pip3.14"], @[]],
        @[@"which yt-dlp", @0, @[@"/usr/bin/yt-dlp"], @[]],
        @[@"yt-dlp --version", @0, @[@"2026.08.19"], @[]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(ytDlpTestPath)], @0,
          @[@"curl_cffi / yt-dlp embedded integration passed"], @[]],
        @[@"ls /usr/bin", @0, @[@"pip", @"pip3", @"pip3.14", @"python", @"python3", @"python3.14"], @[]],
        @[@"python --version", @0, @[@"Python 3.14.7"], @[]],
        @[@"python -V", @0, @[@"Python 3.14.7"], @[]],
        @[@"python -h", @0, @[@"usage: python", @"Supported by ios_system"], @[]],
        @[[NSString stringWithFormat:@"python3.14 -c %@ alpha beta", StaticInlinePythonShellQuote(@"import sys; print('argv ok', sys.argv)")], @0, @[@"argv ok ['-c', 'alpha', 'beta']"], @[]],
        @[@"python '-cprint(314159)'", @0, @[@"314159"], @[]],
        @[[NSString stringWithFormat:@"python %@ left right", StaticInlinePythonShellQuote(scriptPath)], @0, @[@"script ok ['left', 'right']"], @[]],
        @[[NSString stringWithFormat:@"python -- %@ dashdash", StaticInlinePythonShellQuote(scriptPath)], @0, @[@"script ok ['dashdash']"], @[]],
        @[[NSString stringWithFormat:@"python -m json.tool %@", StaticInlinePythonShellQuote(jsonPath)], @0, @[@"\"hello\"", @"314"], @[]],
        @[[NSString stringWithFormat:@"python -mjson.tool %@", StaticInlinePythonShellQuote(jsonPath)], @0, @[@"\"hello\"", @"314"], @[]],
        @[[NSString stringWithFormat:@"python -c %@", StaticInlinePythonShellQuote(@"import mimetypes, tempfile; from openpyxl import Workbook; print('mimetype files', mimetypes.knownfiles); wb = Workbook(); wb.active['A1'] = 'ok'; wb.save(tempfile.gettempdir() + '/static_inline_openpyxl.xlsx'); print('openpyxl save ok')")], @0, @[@"mimetype files []", @"openpyxl save ok"], @[]],
        @[[NSString stringWithFormat:@"python - < %@", StaticInlinePythonShellQuote(stdinPath)], @0, @[@"stdin ok"], @[]],
        @[[NSString stringWithFormat:@"python - arg1 arg2 < %@", StaticInlinePythonShellQuote(stdinArgumentsPath)], @0, @[@"stdin argv ['-', 'arg1', 'arg2']"], @[]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(cairosvgTestPath)], @0, @[@"cairosvg rendering suite ok"], @[]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(cairosvgTestPath)], @0, @[@"cairosvg rendering suite ok"], @[]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(cairosvgSubinterpreterPath)], @0, @[@"cairosvg subinterpreter rejection ok"], @[]],
        @[@"python -m cairosvg cairo-input.svg -o cairo-cli.png", @0, @[], @[]],
        @[@"python -c \"from PIL import Image; image = Image.open('cairo-cli.png'); assert image.size == (64, 48); print('cairosvg cli ok')\"", @0, @[@"cairosvg cli ok"], @[]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(pillowCodecsTestPath)], @0, @[@"pillow codec suite ok"], @[]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(recursivePath)], @0, @[@"outer before", @"inner ok", @"outer after 0"], @[]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(recursiveFailurePath)], @0, @[@"recursive failure status 5"], @[]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(recursiveIsolationPath)], @0, @[@"recursive marker exists False"], @[]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(hfXetRecursivePath)], @0, @[@"hf_xet recursive status 1"], @[@"does not support loading in subinterpreters"]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(safetensorsRecursivePath)], @0, @[@"safetensors recursive status 1"], @[@"does not support loading in subinterpreters"]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(regexRecursivePath)], @0, @[@"regex recursive status 1"], @[@"does not support loading in subinterpreters"]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(tokenizersRecursivePath)], @0, @[@"tokenizers recursive status 1"], @[@"does not support loading in subinterpreters"]],
        @[[NSString stringWithFormat:@"python %@", StaticInlinePythonShellQuote(sentencepieceRecursivePath)], @0, @[@"sentencepiece recursive status 1"], @[@"does not support loading in subinterpreters"]],
        @[@"python -B -c \"import sys; print('dont bytecode', sys.dont_write_bytecode)\"", @0, @[@"dont bytecode True"], @[]],
        @[@"python -S -E -I -s -u -q -b -O -W default -X utf8 -c \"print('separate options ok')\"", @0, @[@"separate options ok"], @[]],
        @[@"python -Wdefault -Xutf8 --check-hash-based-pycs default -c \"print('attached options ok')\"", @0, @[@"attached options ok"], @[]],
        @[@"python -c \"import argparse, bz2, collections, ctypes, dataclasses, decimal, json, math, pathlib, sqlite3, statistics, tempfile, textwrap, threading, unittest, urllib.parse, zlib; print('stdlib imports ok')\"", @0, @[@"stdlib imports ok"], @[]],
        @[@"python -c \"import certifi, hashlib, lzma, requests, ssl, sqlite3, urllib3; import compression.zstd; from packaging.version import Version; ssl.create_default_context(cafile=certifi.where()); sqlite3.connect(':memory:').execute('select 1'); assert str(Version('1.2')) == '1.2'; print('requests imports ok', requests.__version__)\"", @0, @[@"requests imports ok 2.34.2"], @[]],
        @[@"python -c \"import importlib.metadata as md, io; from tqdm import tqdm; output = io.StringIO(); assert list(tqdm(range(3), file=output, mininterval=0)) == [0, 1, 2]; assert '3/3' in output.getvalue(); print('tqdm ok', md.version('tqdm'))\"", @0, @[@"tqdm ok 4.70.0"], @[]],
        @[@"python -c \"import importlib.metadata as md, yaml; value = yaml.safe_load('name: local-code\\nitems:\\n  - 1\\n  - 2\\n'); assert value == {'name': 'local-code', 'items': [1, 2]}; assert yaml.safe_load(yaml.safe_dump(value)) == value; assert yaml.__with_libyaml__ is False; print('pyyaml ok', md.version('PyYAML'), yaml.__with_libyaml__)\"", @0, @[@"pyyaml ok 6.0.3 False"], @[]],
        @[@"python -c \"import importlib.metadata as md, regex; assert regex.fullmatch(r'(?V1)(?i)straße', 'STRASSE'); assert regex.findall(r'\\p{Script=Greek}+', 'abc Ελληνικά') == ['Ελληνικά']; print('regex ok', md.version('regex'))\"", @0, @[@"regex ok 2026.7.19"], @[]],
        @[@"python -c \"import asyncio, importlib.metadata as md; from tokenizers import Tokenizer; from tokenizers.models import WordLevel; from tokenizers.pre_tokenizers import Whitespace; tokenizer = Tokenizer(WordLevel({'[UNK]': 0, 'hello': 1, 'world': 2}, unk_token='[UNK]')); tokenizer.pre_tokenizer = Whitespace(); batch = tokenizer.encode_batch(['hello world'] * 128); assert all(item.ids == [1, 2] for item in batch); namespace = {}; exec(\\\"async def encode(tokenizer):\\\\n    return await tokenizer.async_encode('hello world')\\\", namespace); assert asyncio.run(namespace['encode'](tokenizer)).ids == [1, 2]; print('tokenizers ok', md.version('tokenizers'), len(batch))\"", @0, @[@"tokenizers ok 0.22.2 128"], @[]],
        @[@"python -c \"from tokenizers import Tokenizer; from tokenizers.models import WordLevel; tokenizer = Tokenizer(WordLevel({'[UNK]': 0}, unk_token='[UNK]')); assert tokenizer.encode('missing').ids == [0]; print('tokenizers sequential ok')\"", @0, @[@"tokenizers sequential ok"], @[]],
        @[@"python -c \"import importlib.metadata as md, io, sentencepiece as spm; normalizer = spm.SentencePieceNormalizer(rule_name='nfkc', add_dummy_prefix=False, escape_whitespaces=False, remove_extra_whitespaces=False); assert normalizer.normalize('ＡＢＣ') == 'ABC'; model = io.BytesIO(); spm.SentencePieceTrainer.train(sentence_iterator=iter(['hello world', 'hello local code', 'world of tokenizers'] * 32), model_writer=model, model_type='bpe', vocab_size=32, hard_vocab_limit=False, num_threads=1, minloglevel=2); processor = spm.SentencePieceProcessor(model_proto=model.getvalue()); ids = processor.encode('hello world'); assert processor.decode(ids) == 'hello world'; print('sentencepiece ok', md.version('sentencepiece'), len(ids))\"", @0, @[@"sentencepiece ok 0.2.2"], @[]],
        @[@"python -c \"import sentencepiece as spm; normalizer = spm.SentencePieceNormalizer(rule_name='nfkc', add_dummy_prefix=False, escape_whitespaces=False, remove_extra_whitespaces=False); assert normalizer.normalize('１２３') == '123'; print('sentencepiece sequential ok')\"", @0, @[@"sentencepiece sequential ok"], @[]],
        @[@"python -c \"import importlib.metadata as md, numpy as np; a = np.array([1, 2, 3]); print('numpy imports ok', np.__version__, md.version('numpy'), int(a.sum()))\"", @0, @[@"numpy imports ok 2.4.6 2.4.6 6"], @[]],
        @[@"python -c \"import numpy as np; print('numpy linalg ok', round(float(np.linalg.det(np.array([[1.0, 2.0], [3.0, 4.0]]))), 6))\"", @0, @[@"numpy linalg ok -2.0"], @[]],
        @[@"python -c \"import numpy as np; print('numpy random ok', np.random.default_rng(1).integers(10, size=3).tolist()); print('numpy fft ok', np.fft.fft(np.array([1.0, 0.0])).tolist())\"", @0, @[@"numpy random ok [4, 5, 7]", @"numpy fft ok [(1+0j), (1+0j)]"], @[]],
        @[@"python -c \"import importlib.metadata as md, numpy as np, os, tempfile; from safetensors.numpy import load_file, save_file; path = os.path.join(tempfile.gettempdir(), 'pythonios.safetensors'); expected = np.arange(6, dtype=np.float32).reshape(2, 3); save_file({'values': expected}, path, metadata={'source': 'pythonios'}); actual = load_file(path); assert np.array_equal(actual['values'], expected); print('safetensors ok', md.version('safetensors'), float(actual['values'].sum()))\"", @0, @[@"safetensors ok 0.8.0 15.0"], @[]],
        @[@"python -c \"import hf_xet, importlib.metadata as md; session = hf_xet.XetSession(); assert session.status() == hf_xet.XetTaskState.Running; session.sigint_abort(); print('hf_xet session ok', md.version('hf-xet'))\"", @0, @[@"hf_xet session ok 1.5.2"], @[]],
        @[@"python -c \"import hf_xet; session = hf_xet.XetSession(); assert session.status() == hf_xet.XetTaskState.Running; session.sigint_abort(); print('hf_xet sequential session ok')\"", @0, @[@"hf_xet sequential session ok"], @[]],
#if !TARGET_OS_SIMULATOR
        @[@"python -c \"import importlib.metadata as md, mlx.core as mx; mx.set_default_device(mx.cpu); values = mx.array([1, 2, 3]); print('mlx cpu ok', mx.__version__, md.version('mlx'), mx.sum(values).item())\"", @0, @[@"mlx cpu ok 0.32.2 0.32.2 6"], @[]],
        @[@"python -c \"import mlx.core as mx; assert mx.is_available(mx.gpu); mx.set_default_device(mx.gpu); values = mx.arange(4); mx.eval(values); print('mlx metal ok', values.tolist())\"", @0, @[@"mlx metal ok [0, 1, 2, 3]"], @[]],
#endif
        @[@"python -c \"import io, pandas as pd; from PIL import Image; from lxml import etree; import contourpy, kiwisolver, matplotlib; matplotlib.use('Agg'); from matplotlib import pyplot as plt; from psd_tools import PSDImage; frame = pd.DataFrame({'x': [1, 2, 3]}); assert int(frame.x.sum()) == 6; image = Image.new('RGB', (2, 3)); image_bytes = io.BytesIO(); image.save(image_bytes, format='PNG'); assert image_bytes.tell() > 0; root = etree.fromstring(b'<root><v>ok</v></root>'); assert root[0].text == 'ok'; contour = contourpy.contour_generator(x=[0, 1], y=[0, 1], z=[[0, 1], [1, 0]]).lines(0.5); assert len(contour) > 0; variable = kiwisolver.Variable('x'); solver = kiwisolver.Solver(); solver.addConstraint(variable == 7); solver.updateVariables(); assert variable.value() == 7; figure = plt.figure(); plt.plot([0, 1], [1, 0]); figure.canvas.draw(); plt.close(figure); psd = PSDImage.new(mode='RGB', size=(2, 2)); psd_bytes = io.BytesIO(); psd.save(psd_bytes); assert psd_bytes.tell() > 0; print('native package suite ok')\"", @0, @[@"native package suite ok"], @[]],
        @[@"python -m pip --version", @0, @[@"pip 26.2.1"], @[]],
        @[@"pip --version", @0, @[@"pip 26.2.1"], @[]],
        @[@"pip3.14 --version", @0, @[@"pip 26.2.1"], @[]],
        @[[NSString stringWithFormat:@"python %@ %@ %@", StaticInlinePythonShellQuote(pipFixtureBuilderPath), StaticInlinePythonShellQuote(huggingfaceHubFixtureDirectory), StaticInlinePythonShellQuote(huggingfaceHubFixtureWheelPath)], @0, @[@"pip fixture wheel created"], @[]],
        @[[NSString stringWithFormat:@"python %@ %@ %@", StaticInlinePythonShellQuote(pipFixtureBuilderPath), StaticInlinePythonShellQuote(pipFixtureDirectory), StaticInlinePythonShellQuote(pipFixtureWheelPath)], @0, @[@"pip fixture wheel created"], @[]],
        @[[NSString stringWithFormat:@"pip install --no-index --no-cache-dir --find-links %@ %@", StaticInlinePythonShellQuote(directory), StaticInlinePythonShellQuote(pipFixtureWheelPath)], @0, @[@"Requirement already satisfied: numpy>=2", @"Requirement already satisfied: hf-xet>=1.5.2", @"Requirement already satisfied: safetensors>=0.8.0", @"Requirement already satisfied: regex>=2025.10.22", @"Requirement already satisfied: tokenizers<=0.23.0,>=0.22.0", @"Requirement already satisfied: sentencepiece<0.3,>=0.2.2", @"Successfully installed huggingface-hub-1.5.0 ios-pip-probe-1.0"], @[]],
        @[@"python -c \"import hf_xet, huggingface_hub, importlib.metadata as md, ios_pip_probe, numpy, os, regex, safetensors, sentencepiece, tokenizers; prefix = os.path.realpath(os.environ['PIP_PREFIX']); print('pip project install', ios_pip_probe.VALUE, md.version('ios-pip-probe'), os.path.realpath(ios_pip_probe.__file__).startswith(prefix + os.sep)); print('pip project hub', md.version('huggingface-hub'), os.path.realpath(huggingface_hub.__file__).startswith(prefix + os.sep)); print('pip bundled dependency', md.version('numpy'), not os.path.realpath(numpy.__file__).startswith(prefix + os.sep)); print('pip bundled hf_xet', md.version('hf-xet'), not os.path.realpath(hf_xet.__file__).startswith(prefix + os.sep)); print('pip bundled safetensors', md.version('safetensors'), not os.path.realpath(safetensors.__file__).startswith(prefix + os.sep)); print('pip bundled regex', md.version('regex'), not os.path.realpath(regex.__file__).startswith(prefix + os.sep)); print('pip bundled tokenizers', md.version('tokenizers'), not os.path.realpath(tokenizers.__file__).startswith(prefix + os.sep)); print('pip bundled sentencepiece', md.version('sentencepiece'), not os.path.realpath(sentencepiece.__file__).startswith(prefix + os.sep))\"", @0, @[@"pip project install project-local 1.0 True", @"pip project hub 1.5.0 True", @"pip bundled dependency 2.4.6 True", @"pip bundled hf_xet 1.5.2 True", @"pip bundled safetensors 0.8.0 True", @"pip bundled regex 2026.7.19 True", @"pip bundled tokenizers 0.22.2 True", @"pip bundled sentencepiece 0.2.2 True"], @[]],
        @[@"pip check", @0, @[@"No broken requirements found."], @[]],
        @[@"python -c \"globals()['main_leak_marker'] = 1; print('set main marker')\"", @0, @[@"set main marker"], @[]],
        @[@"python -c \"print('main marker exists', 'main_leak_marker' in globals())\"", @0, @[@"main marker exists False"], @[]],
        @[@"python -c \"print('bootstrap marker exists', '_ios_run' in globals(), '_ios_exit_code' in globals())\"", @0, @[@"bootstrap marker exists False False"], @[]],
        @[@"python -c \"import builtins; builtins._ios_leak_marker = 1; print('set marker')\"", @0, @[@"set marker"], @[]],
        @[@"python -c \"import builtins; print('marker exists', hasattr(builtins, '_ios_leak_marker'))\"", @0, @[@"marker exists False"], @[]],
        @[@"python -c \"import importlib.util; print('late package spec', importlib.util.find_spec('late_pkg'))\"", @0, @[@"late package spec None"], @[]],
        @[@"python", @0, @[], @[@"interactive mode is not supported by ios_system yet"]],
        @[@"python -c", @2, @[], @[@"argument expected for the -c option"]],
        @[@"python -m", @2, @[], @[@"argument expected for the -m option"]],
        @[@"python -Z", @2, @[], @[@"unsupported option -Z"]],
        @[@"python -c \"raise SystemExit(7)\"", @7, @[], @[]],
        @[@"python -c \"raise SystemExit('bad exit')\"", @1, @[], @[@"bad exit"]],
        @[@"python -c \"raise ValueError('boom')\"", @1, @[], @[@"ValueError: boom"]],
        @[@"python -c \"if True print('bad')\"", @1, @[], @[@"SyntaxError"]],
        @[@"python -m definitely_missing_ios_system_module", @1, @[], @[@"No module named definitely_missing_ios_system_module"]],
    ];

    NSUInteger index = 0;
    for (NSArray *commandAndExpectations in commands) {
        NSString *command = commandAndExpectations[0];
        int expectedStatus = [commandAndExpectations[1] intValue];
        NSArray<NSString *> *expectedStdoutFragments = commandAndExpectations[2];
        NSArray<NSString *> *expectedStderrFragments = commandAndExpectations[3];
        int commandStatus = StaticInlinePythonRunCommand(command, expectedStatus, expectedStdoutFragments, expectedStderrFragments, directory, index);
        if (commandStatus != 0) {
            return commandStatus;
        }
        index++;
    }

    status = 0;
    status |= StaticInlinePythonCreateDirectory(latePackagePath);
    status |= StaticInlinePythonWriteFile([latePackagePath stringByAppendingPathComponent:@"__init__.py"], @"from ._monitor import VALUE\n");
    status |= StaticInlinePythonWriteFile([latePackagePath stringByAppendingPathComponent:@"_monitor.py"], @"VALUE = 'late package ok'\n");
    status |= StaticInlinePythonCreateDirectory(refreshPackagePath);
    status |= StaticInlinePythonWriteFile([refreshPackagePath stringByAppendingPathComponent:@"__init__.py"], @"VALUE = 'before refresh'\n");
    if (status != 0) {
        return status;
    }

    NSString *latePackageCommand = [NSString stringWithFormat:@"python -c %@",
        StaticInlinePythonShellQuote(@"import late_pkg; print('late package', late_pkg.VALUE)")];
    if (StaticInlinePythonRunCommand(latePackageCommand, 0, @[@"late package late package ok"], @[], directory, index) != 0) {
        return 1;
    }
    index++;

    NSString *refreshPackageBeforeCommand = [NSString stringWithFormat:@"python -c %@",
        StaticInlinePythonShellQuote(@"import refresh_pkg; print('refresh package', refresh_pkg.VALUE)")];
    if (StaticInlinePythonRunCommand(refreshPackageBeforeCommand, 0, @[@"refresh package before refresh"], @[], directory, index) != 0) {
        return 1;
    }
    index++;

    status = StaticInlinePythonWriteFile([refreshPackagePath stringByAppendingPathComponent:@"__init__.py"], @"VALUE = 'after refresh'\n");
    if (status != 0) {
        return status;
    }
    NSString *refreshPackageAfterCommand = [NSString stringWithFormat:@"python -c %@",
        StaticInlinePythonShellQuote(@"import refresh_pkg; print('refresh package', refresh_pkg.VALUE)")];
    if (StaticInlinePythonRunCommand(refreshPackageAfterCommand, 0, @[@"refresh package after refresh"], @[], directory, index) != 0) {
        return 1;
    }
    index++;

    NSString *projectACommand = [NSString stringWithFormat:@"python -c %@",
        StaticInlinePythonShellQuote(@"import os, local_marker; print('project marker', local_marker.VALUE); print('workspace home', os.path.dirname(os.getcwd()) == os.environ.get('HOME')); print('project pwd cwd', os.environ.get('PWD') == os.getcwd()); print('pip prefix ok', os.environ.get('PIP_PREFIX', '').endswith('/project-a/.localc/python')); print('pip target unset', 'PIP_TARGET' not in os.environ)")];
    if (StaticInlinePythonRunCommand(projectACommand, 0, @[@"project marker project-a", @"workspace home True", @"project pwd cwd True", @"pip prefix ok True", @"pip target unset True"], @[], directory, index) != 0) {
        return 1;
    }
    index++;

    if (ios_setSystemPaths(
            [NSURL fileURLWithPath:systemDocumentsPath isDirectory:YES],
            [NSURL fileURLWithPath:systemLibraryPath isDirectory:YES],
            [NSURL fileURLWithPath:systemCachesPath isDirectory:YES],
            [NSURL fileURLWithPath:directory isDirectory:YES],
            [NSURL fileURLWithPath:projectBPath isDirectory:YES],
            [NSURL fileURLWithPath:directory isDirectory:YES]) == 0) {
        fprintf(stderr, "[StaticInlinePython] failed setting project-b system paths\n");
        return 1;
    }
    ios_setDirectoryURL([NSURL fileURLWithPath:projectBPath isDirectory:YES]);
    NSString *projectBCommand = [NSString stringWithFormat:@"python -c %@",
        StaticInlinePythonShellQuote(@"import os, sys, local_marker; paths = [p for p in sys.path if '.localc/python/lib/python3.14/site-packages' in p]; print('project marker', local_marker.VALUE); print('workspace home', os.path.dirname(os.getcwd()) == os.environ.get('HOME')); print('project pwd cwd', os.environ.get('PWD') == os.getcwd()); print('pip prefix ok', os.environ.get('PIP_PREFIX', '').endswith('/project-b/.localc/python')); print('pip target unset', 'PIP_TARGET' not in os.environ); print('stale project-a path', any('/project-a/.localc/python/lib/python3.14/site-packages' in p for p in paths)); print('project paths', paths)")];
    if (StaticInlinePythonRunCommand(projectBCommand, 0, @[@"project marker project-b", @"workspace home True", @"project pwd cwd True", @"pip prefix ok True", @"pip target unset True", @"stale project-a path False", @"project-b/.localc/python/lib/python3.14/site-packages"], @[], directory, index) != 0) {
        return 1;
    }
    index++;

    if (ios_setSystemPaths(
            [NSURL fileURLWithPath:systemDocumentsPath isDirectory:YES],
            [NSURL fileURLWithPath:systemLibraryPath isDirectory:YES],
            [NSURL fileURLWithPath:systemCachesPath isDirectory:YES],
            [NSURL fileURLWithPath:directory isDirectory:YES],
            [NSURL fileURLWithPath:directory isDirectory:YES],
            [NSURL fileURLWithPath:directory isDirectory:YES]) == 0) {
        fprintf(stderr, "[StaticInlinePython] failed setting workspace project system paths\n");
        return 1;
    }
    ios_setDirectoryURL([NSURL fileURLWithPath:directory isDirectory:YES]);
    NSString *workspaceProjectCommand = [NSString stringWithFormat:@"python -c %@",
        StaticInlinePythonShellQuote(@"import os; print('workspace project home cwd', os.environ.get('HOME') == os.getcwd()); print('workspace project pwd cwd', os.environ.get('PWD') == os.getcwd())")];
    if (StaticInlinePythonRunCommand(workspaceProjectCommand, 0, @[@"workspace project home cwd True", @"workspace project pwd cwd True"], @[], directory, index) != 0) {
        return 1;
    }
    return 0;
}

#if !STATIC_INLINE_PYTHON_UIKIT_APP
typedef struct {
    const void *sessionName;
    const char *command;
    int status;
} StaticInlinePythonCommandContext;

static void *StaticInlinePythonCommandWorker(void *context) {
    StaticInlinePythonCommandContext *commandContext =
        (StaticInlinePythonCommandContext *)context;
    ios_switchSession(commandContext->sessionName);
    ios_setStreams(stdin, stdout, stderr);
    commandContext->status =
        ios_system_osh(commandContext->command);
    fprintf(
        stderr,
        "[StaticInlinePython] cancelled command returned status=%d\n",
        commandContext->status);
    fflush(stderr);
    return NULL;
}

static int StaticInlinePythonRunCancellationCase(
    const void *sessionName,
    const char *command,
    NSString *readyPath,
    useconds_t fallbackDelay)
{
    ios_switchSession(sessionName);
    ios_setStreams(stdin, stdout, stderr);

    StaticInlinePythonCommandContext context = {
        .sessionName = sessionName,
        .command = command,
        .status = -1,
    };
    pthread_t commandThread = NULL;
    // The command needs its own thread so this test thread can call the
    // synchronous ios_kill while the command is still running.
    int createStatus = pthread_create(
        &commandThread, NULL, StaticInlinePythonCommandWorker, &context);
    if (createStatus != 0) {
        fprintf(stderr, "[StaticInlinePython] pthread_create failed: %d\n", createStatus);
        return 1;
    }

    if (readyPath != nil) {
        for (int attempt = 0;
             attempt < 5000 &&
             ![NSFileManager.defaultManager fileExistsAtPath:readyPath];
             attempt++) {
            usleep(1000);
        }
        if (![NSFileManager.defaultManager fileExistsAtPath:readyPath]) {
            fprintf(
                stderr,
                "[StaticInlinePython] command did not reach its ready point\n");
            ios_switchSession(sessionName);
            ios_kill();
            pthread_join(commandThread, NULL);
            return 1;
        }
    } else {
        usleep(fallbackDelay);
    }
    ios_switchSession(sessionName);
    int cancellationStatus = ios_kill();
    fprintf(
        stderr,
        "[StaticInlinePython] cancellation requested, status=%d\n",
        cancellationStatus);
    fflush(stderr);

    pthread_join(commandThread, NULL);
    if (cancellationStatus != 0 || context.status != 130) {
        fprintf(
            stderr,
            "[StaticInlinePython] expected cancellation status=0 and command status=130\n");
        return 1;
    }
    return 0;
}

static int StaticInlinePythonRunCancellationReproducer(void) {
    ios_setStreams(stdin, stdout, stderr);
    initializeEnvironment();
    StaticInlinePythonConfigurePythonEnvironment();

    // The unfixed startup case waits forever, so keep an external watchdog
    // around this mode when comparing against an older ios_system build.
    static char startupSessionName[] =
        "static-inline-python-startup-cancellation";
    const char *delayText =
        getenv("STATIC_INLINE_PYTHON_CANCEL_DELAY_US");
    useconds_t startupDelay = delayText != NULL
        ? (useconds_t)strtoul(delayText, NULL, 10)
        : 1000;
    if (StaticInlinePythonRunCancellationCase(
            startupSessionName,
            "pip install --no-index --no-cache-dir numpy",
            nil,
            startupDelay) != 0) {
        return 1;
    }
    fprintf(stderr, "[StaticInlinePython] starting pip after startup cancellation\n");
    fflush(stderr);
    if (ios_system_osh("pip --version") != 0) {
        return 1;
    }

    NSString *directory = [
        NSTemporaryDirectory()
        stringByAppendingPathComponent:[
            NSString stringWithFormat:
                @"StaticInlinePythonCancellation-%d", getpid()]];
    if (StaticInlinePythonCreateDirectory(directory) != 0) {
        return 1;
    }
    NSString *loopPath =
        [directory stringByAppendingPathComponent:@"loop.py"];
    NSString *outerPath =
        [directory stringByAppendingPathComponent:@"outer.py"];
    if (StaticInlinePythonWriteFile(
            loopPath,
            @"import pathlib, sys\npathlib.Path(sys.argv[1]).write_text('ready')\nwhile True:\n    pass\n") != 0 ||
        StaticInlinePythonWriteFile(
            outerPath,
            @"import os, sys\nraise SystemExit(os.system('python ' + sys.argv[1] + ' ' + sys.argv[2]))\n") != 0) {
        return 1;
    }

    static char activeSessionName[] =
        "static-inline-python-active-cancellation";
    NSString *activeReadyPath =
        [directory stringByAppendingPathComponent:@"active-ready"];
    NSString *activeCommand = [NSString stringWithFormat:
        @"python %@ %@",
        StaticInlinePythonShellQuote(loopPath),
        StaticInlinePythonShellQuote(activeReadyPath)];
    if (StaticInlinePythonRunCancellationCase(
            activeSessionName,
            activeCommand.UTF8String,
            activeReadyPath,
            0) != 0) {
        return 1;
    }
    if (ios_system_osh("python -c \"print('active cancellation recovered')\"") != 0) {
        return 1;
    }

    static char nestedSessionName[] =
        "static-inline-python-nested-cancellation";
    NSString *nestedReadyPath =
        [directory stringByAppendingPathComponent:@"nested-ready"];
    NSString *nestedCommand = [NSString stringWithFormat:
        @"python %@ %@ %@",
        StaticInlinePythonShellQuote(outerPath),
        StaticInlinePythonShellQuote(loopPath),
        StaticInlinePythonShellQuote(nestedReadyPath)];
    if (StaticInlinePythonRunCancellationCase(
            nestedSessionName,
            nestedCommand.UTF8String,
            nestedReadyPath,
            0) != 0) {
        return 1;
    }
    if (ios_system_osh(
            "python -c \"print('nested cancellation recovered')\"") != 0) {
        return 1;
    }

    // Stopping a job blocked in a foreground command stops the whole job, not
    // only that command.
    static char foregroundSessionName[] =
        "static-inline-python-foreground-cancellation";
    NSString *foregroundReadyPath =
        [directory stringByAppendingPathComponent:@"foreground-ready"];
    NSString *foregroundCommand = [NSString stringWithFormat:
        @"touch %@; sleep 30; echo continued; exit 0",
        StaticInlinePythonShellQuote(foregroundReadyPath)];
    if (StaticInlinePythonRunCancellationCase(
            foregroundSessionName,
            foregroundCommand.UTF8String,
            foregroundReadyPath,
            0) != 0) {
        return 1;
    }

    // The same holds inside a nested shell: neither shell may continue with
    // its next command.
    static char shellSessionName[] =
        "static-inline-python-nested-shell-cancellation";
    NSString *shellReadyPath =
        [directory stringByAppendingPathComponent:@"shell-ready"];
    NSString *shellCommand = [NSString stringWithFormat:
        @"sh -c %@ sh %@; echo outer-continued; exit 0",
        StaticInlinePythonShellQuote(@"touch \"$1\"; sleep 30; echo nested-continued"),
        StaticInlinePythonShellQuote(shellReadyPath)];
    if (StaticInlinePythonRunCancellationCase(
            shellSessionName,
            shellCommand.UTF8String,
            shellReadyPath,
            0) != 0) {
        return 1;
    }
    return ios_system_osh(
        "sh -c 'echo nested shell cancellation recovered'");
}

static int StaticInlinePythonRunOneCommand(int argc, char *argv[]) {
    if (argc < 2) {
        return 2;
    }
    ios_setStreams(stdin, stdout, stderr);
    initializeEnvironment();
    StaticInlinePythonConfigurePythonEnvironment();

    return ios_system(argc - 1, (const char *const *)(argv + 1));
}
#endif

#if STATIC_INLINE_PYTHON_UIKIT_APP

@interface StaticInlinePythonAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation StaticInlinePythonAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.systemBackgroundColor;
    [self.window makeKeyAndVisible];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = StaticInlinePythonRunSuite();
        fprintf(stderr, "\n[StaticInlinePython] suite %s\n", status == 0 ? "passed" : "failed");
        fflush(stdout);
        fflush(stderr);
        exit(status == 0 ? 0 : 1);
    });
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(StaticInlinePythonAppDelegate.class));
    }
}

#else

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (getenv("STATIC_INLINE_PYTHON_CANCEL_REPRO") != NULL) {
            return StaticInlinePythonRunCancellationReproducer();
        }
        if (argc > 1) {
            return StaticInlinePythonRunOneCommand(argc, argv);
        }
        int status = StaticInlinePythonRunSuite();
        fprintf(stderr, "\n[StaticInlinePython] suite %s\n", status == 0 ? "passed" : "failed");
        fflush(stdout);
        fflush(stderr);
        return status == 0 ? 0 : 1;
    }
}

#endif
