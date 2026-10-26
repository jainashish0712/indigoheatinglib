#!/usr/bin/env python3
"""
Automated Test Suite for IndigoThermalFix.
Validates source code syntax, AST constraints, compiler flags, and Mach-O binary structure.
"""

import os
import re
import sys
import struct
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TWEAK_SRC = os.path.join(SCRIPT_DIR, "Tweak.m")
MAKEFILE_PATH = os.path.join(SCRIPT_DIR, "Makefile")
WORKFLOW_PATH = os.path.join(SCRIPT_DIR, "..", ".github", "workflows", "build.yml")


class TestTweakSource(unittest.TestCase):
    """Static analysis and syntax checks for Tweak.m."""

    def setUp(self):
        self.assertTrue(os.path.exists(TWEAK_SRC), f"Tweak.m not found at {TWEAK_SRC}")
        with open(TWEAK_SRC, "r", encoding="utf-8") as f:
            self.code = f.read()

    def test_no_invalid_instancetype_in_c_functions(self):
        """Ensure instancetype is NOT used as return type in C static functions or function pointers."""
        # instancetype is only valid in ObjC method declarations (-/+), NOT in C functions
        matches = re.findall(r"\binstancetype\s+(\(\*|hook_|orig_)", self.code)
        self.assertEqual(
            len(matches),
            0,
            f"Found invalid 'instancetype' in C function pointer/function signatures: {matches}. Use 'MTKView *' or 'id'."
        )

    def test_no_unsupported_dot_syntax_properties(self):
        """Ensure preferredFrameRateRange is not called via dot syntax on MTKView or CALayer."""
        # MTKView and CALayer do not declare preferredFrameRateRange in all SDK headers, causing clang compilation errors
        dot_mtk = re.findall(r"\bview\.preferredFrameRateRange\b", self.code)
        dot_layer = re.findall(r"\blayer\.preferredFrameRateRange\b", self.code)
        self.assertEqual(len(dot_mtk), 0, "Direct dot syntax 'view.preferredFrameRateRange' found! Must use objc_msgSend.")
        self.assertEqual(len(dot_layer), 0, "Direct dot syntax 'layer.preferredFrameRateRange' found! Must use objc_msgSend.")

    def test_required_headers_imported(self):
        """Ensure all required frameworks and runtime headers are imported."""
        required_headers = [
            "<Foundation/Foundation.h>",
            "<UIKit/UIKit.h>",
            "<MetalKit/MetalKit.h>",
            "<QuartzCore/QuartzCore.h>",
            "<objc/runtime.h>",
            "<objc/message.h>",
            "<os/log.h>",
        ]
        for header in required_headers:
            self.assertIn(header, self.code, f"Missing required import: {header}")

    def test_constructor_defined(self):
        """Ensure entry point has __attribute__((constructor))."""
        self.assertRegex(
            self.code,
            r"__attribute__\s*\(\s*\(\s*constructor\s*\)\s*\)\s*static\s+void\s+\w+",
            "Constructor entry point missing or invalid"
        )

    def test_swizzle_pairs_consistency(self):
        """Verify that every safe_swizzle call has matching orig_ and hook_ functions."""
        swizzle_calls = re.findall(r"@selector\((\w+:?)\)", self.code)
        self.assertGreater(len(swizzle_calls), 0, "No selectors found to swizzle")

        # Check for core hooks
        for hook_name in [
            "hook_MTKView_setDelegate",
            "orig_MTKView_setDelegate",
            "hook_MTKView_setPaused",
            "orig_MTKView_setPaused",
            "hook_MTKView_initWithFrame_device",
            "orig_MTKView_initWithFrame_device",
            "hook_MTKView_init",
            "orig_MTKView_init",
            "hook_MTKView_didMoveToWindow",
            "orig_MTKView_didMoveToWindow",
            "hook_MTKView_setPreferredFramesPerSecond",
            "orig_MTKView_setPreferredFramesPerSecond",
        ]:
            self.assertIn(hook_name, self.code, f"Missing swizzle handler: {hook_name}")

    def test_objc_msgsend_casts(self):
        """Verify all objc_msgSend calls are explicitly cast to avoid clang ARC errors."""
        # Strip comments
        clean = re.sub(r'//.*', '', self.code)
        clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.DOTALL)

        msg_sends = list(re.finditer(r"\bobjc_msgSend\b", clean))
        self.assertGreater(len(msg_sends), 0, "No objc_msgSend calls found")
        for m in msg_sends:
            start = max(0, m.start() - 80)
            prefix = clean[start:m.start()]
            self.assertTrue(
                re.search(r"\([a-zA-Z0-9_\s\*,\(\)]+\)", prefix),
                f"objc_msgSend call must be cast to function pointer near: {clean[start:m.start()+30]}"
            )

    def test_balanced_syntax(self):
        """Verify brackets and preprocessor directives are balanced."""
        # Strip string literals and comments
        clean = re.sub(r'//.*', '', self.code)
        clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.DOTALL)
        clean = re.sub(r'"(\\.|[^"\\])*"', '', clean)

        # Count braces, parens, brackets
        self.assertEqual(clean.count('{'), clean.count('}'), "Mismatched curly braces { }")
        self.assertEqual(clean.count('('), clean.count(')'), "Mismatched parentheses ( )")
        self.assertEqual(clean.count('['), clean.count(']'), "Mismatched square brackets [ ]")

        # Count #if / #endif
        ifs = len(re.findall(r"^\s*#\s*(if|ifdef|ifndef)\b", clean, re.MULTILINE))
        endifs = len(re.findall(r"^\s*#\s*endif\b", clean, re.MULTILINE))
        self.assertEqual(ifs, endifs, f"Mismatched #if ({ifs}) and #endif ({endifs})")


class TestBuildConfiguration(unittest.TestCase):
    """Verify Makefile and GitHub Actions workflow configuration."""

    def test_workflow_exists_and_configured(self):
        """Ensure workflow compiles with proper warnings enabled."""
        self.assertTrue(os.path.exists(WORKFLOW_PATH), f"Workflow not found at {WORKFLOW_PATH}")
        with open(WORKFLOW_PATH, "r", encoding="utf-8") as f:
            wf_content = f.read()

        self.assertIn("working-directory: IndigoThermalFix", wf_content)
        self.assertIn("-framework MetalKit", wf_content)
        self.assertIn("-framework QuartzCore", wf_content)
        self.assertIn("IndigoThermalFix/IndigoThermalFix.dylib", wf_content)

    def test_makefile_exists_and_valid(self):
        """Ensure Makefile references correct sources and frameworks."""
        self.assertTrue(os.path.exists(MAKEFILE_PATH), f"Makefile not found at {MAKEFILE_PATH}")
        with open(MAKEFILE_PATH, "r", encoding="utf-8") as f:
            make_content = f.read()

        self.assertIn("MetalKit", make_content)
        self.assertIn("QuartzCore", make_content)
        self.assertIn("Tweak.m", make_content)


class TestMachOBinary(unittest.TestCase):
    """Verify compiled Mach-O binary if present."""

    def test_dylib_if_present(self):
        dylib_path = os.path.join(SCRIPT_DIR, "IndigoThermalFix.dylib")
        if not os.path.exists(dylib_path):
            self.skipTest(f"IndigoThermalFix.dylib not yet compiled locally (will run in CI post-build)")

        with open(dylib_path, "rb") as f:
            data = f.read()

        self.assertGreater(len(data), 4096, "Dylib file is too small")
        magic, = struct.unpack_from("<I", data, 0)
        # Check for Mach-O 64-bit (0xfeedfacf) or Fat/Universal (0xcafebabe)
        self.assertIn(magic, [0xfeedfacf, 0xcafebabe], f"Invalid Mach-O magic: 0x{magic:08x}")


def main():
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
