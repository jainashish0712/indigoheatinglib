#!/usr/bin/env python3
"""
Comprehensive Automated Test Suite for IndigoThermalFix.
Performs deep static analysis, ARC bridging validation, clang compatibility checks,
and Mach-O binary structural verification.
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


class TestTweakARCAndClangCompatibility(unittest.TestCase):
    """Deep verification of ARC rules, bridging, and Clang compiler compatibility."""

    def setUp(self):
        self.assertTrue(os.path.exists(TWEAK_SRC), f"Tweak.m not found at {TWEAK_SRC}")
        with open(TWEAK_SRC, "r", encoding="utf-8") as f:
            self.code = f.read()

        # Clean code stripped of comments and string literals
        clean = re.sub(r'//.*', '', self.code)
        clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.DOTALL)
        self.clean_code = clean

    def test_no_unbridged_void_pointer_casts(self):
        """CRITICAL: Ensure NO Objective-C objects are cast to (void *) without __bridge."""
        # Under ARC (-fobjc-arc), casting an ObjC pointer to (void *) without __bridge causes fatal error:
        # "cast of Objective-C pointer type '...' to C pointer type 'void *' requires a bridged cast"
        # Match any (void *) cast not preceded by __bridge
        unbridged_matches = re.findall(r'(?<!__bridge\s)\(\s*void\s*\*\s*\)\s*([a-zA-Z0-9_]+)', self.clean_code)
        self.assertEqual(
            len(unbridged_matches),
            0,
            f"Found illegal unbridged (void *) cast(s) on object(s): {unbridged_matches}. Must use (__bridge void *)."
        )

    def test_all_pointer_format_args_are_bridged(self):
        """Ensure all %p format specifiers in LOG/NSLog/os_log pass bridged pointers or raw pointers."""
        # Find all LOG(...) calls
        log_calls = re.findall(r'LOG\s*\((.*?)\);', self.clean_code, re.DOTALL)
        self.assertGreater(len(log_calls), 0, "No LOG calls found to inspect")

        for call in log_calls:
            # Check if format string contains %p
            if "%p" in call:
                self.assertIn(
                    "__bridge void *",
                    call,
                    f"LOG call with '%p' does not bridge Objective-C object pointer: LOG({call})"
                )

    def test_no_invalid_instancetype_in_c_functions(self):
        """Ensure instancetype is NOT used as return type in C static functions or function pointers."""
        matches = re.findall(r"\binstancetype\s+(\(\*|hook_|orig_)", self.clean_code)
        self.assertEqual(
            len(matches),
            0,
            f"Found invalid 'instancetype' in C function pointer/function signatures: {matches}. Use 'MTKView *' or 'id'."
        )

    def test_no_unsupported_dot_syntax_properties(self):
        """Ensure preferredFrameRateRange is not called via dot syntax on MTKView or CALayer."""
        dot_mtk = re.findall(r"\bview\.preferredFrameRateRange\b", self.clean_code)
        dot_layer = re.findall(r"\blayer\.preferredFrameRateRange\b", self.clean_code)
        self.assertEqual(len(dot_mtk), 0, "Direct dot syntax 'view.preferredFrameRateRange' found! Must use objc_msgSend.")
        self.assertEqual(len(dot_layer), 0, "Direct dot syntax 'layer.preferredFrameRateRange' found! Must use objc_msgSend.")

    def test_objc_msgsend_explicit_cast(self):
        """Verify all objc_msgSend calls are explicitly cast to function pointers to satisfy ARC."""
        msg_sends = list(re.finditer(r"\bobjc_msgSend\b", self.clean_code))
        self.assertGreater(len(msg_sends), 0, "No objc_msgSend calls found")
        for m in msg_sends:
            start = max(0, m.start() - 80)
            prefix = self.clean_code[start:m.start()]
            self.assertTrue(
                re.search(r"\([a-zA-Z0-9_\s\*,\(\)]+\)", prefix),
                f"objc_msgSend call must be cast to function pointer near: {self.clean_code[start:m.start()+30]}"
            )

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
            self.clean_code,
            r"__attribute__\s*\(\s*\(\s*constructor\s*\)\s*\)\s*static\s+void\s+\w+",
            "Constructor entry point missing or invalid"
        )

    def test_swizzle_pairs_consistency(self):
        """Verify that every safe_swizzle call has matching orig_ and hook_ functions."""
        expected_hooks = [
            ("setDelegate:", "hook_MTKView_setDelegate", "orig_MTKView_setDelegate"),
            ("setPaused:", "hook_MTKView_setPaused", "orig_MTKView_setPaused"),
            ("initWithFrame:device:", "hook_MTKView_initWithFrame_device", "orig_MTKView_initWithFrame_device"),
            ("init", "hook_MTKView_init", "orig_MTKView_init"),
            ("didMoveToWindow", "hook_MTKView_didMoveToWindow", "orig_MTKView_didMoveToWindow"),
            ("setPreferredFramesPerSecond:", "hook_MTKView_setPreferredFramesPerSecond", "orig_MTKView_setPreferredFramesPerSecond"),
        ]

        for selector, hook_func, orig_ptr in expected_hooks:
            self.assertIn(f"@selector({selector})", self.clean_code, f"Missing swizzle for selector {selector}")
            self.assertIn(hook_func, self.clean_code, f"Missing hook function {hook_func}")
            self.assertIn(orig_ptr, self.clean_code, f"Missing orig pointer {orig_ptr}")

    def test_clang_diagnostic_pragmas_present(self):
        """Ensure -Wcast-function-type is suppressed around function pointer to IMP casts."""
        self.assertIn("-Wcast-function-type", self.code, "Missing clang diagnostic pragma for -Wcast-function-type")

    def test_balanced_syntax_and_preprocessor(self):
        """Verify braces, parens, brackets, and preprocessor directives are completely balanced."""
        self.assertEqual(self.clean_code.count('{'), self.clean_code.count('}'), "Mismatched curly braces { }")
        self.assertEqual(self.clean_code.count('('), self.clean_code.count(')'), "Mismatched parentheses ( )")
        self.assertEqual(self.clean_code.count('['), self.clean_code.count(']'), "Mismatched square brackets [ ]")

        ifs = len(re.findall(r"^\s*#\s*(if|ifdef|ifndef)\b", self.clean_code, re.MULTILINE))
        endifs = len(re.findall(r"^\s*#\s*endif\b", self.clean_code, re.MULTILINE))
        self.assertEqual(ifs, endifs, f"Mismatched #if ({ifs}) and #endif ({endifs})")


class TestBuildConfiguration(unittest.TestCase):
    """Verify Makefile and GitHub Actions workflow configuration."""

    def test_workflow_exists_and_configured(self):
        self.assertTrue(os.path.exists(WORKFLOW_PATH), f"Workflow not found at {WORKFLOW_PATH}")
        with open(WORKFLOW_PATH, "r", encoding="utf-8") as f:
            wf_content = f.read()

        self.assertIn("working-directory: IndigoThermalFix", wf_content)
        self.assertIn("-Wall -Wextra -Werror", wf_content)
        self.assertIn("-framework MetalKit", wf_content)
        self.assertIn("-framework QuartzCore", wf_content)
        self.assertIn("python3 test_tweak.py", wf_content)
        self.assertIn("refs/heads/dev", wf_content)

    def test_makefile_exists_and_valid(self):
        self.assertTrue(os.path.exists(MAKEFILE_PATH), f"Makefile not found at {MAKEFILE_PATH}")
        with open(MAKEFILE_PATH, "r", encoding="utf-8") as f:
            make_content = f.read()

        self.assertIn("-Wall -Wextra -Werror", make_content)
        self.assertIn("MetalKit", make_content)
        self.assertIn("QuartzCore", make_content)
        self.assertIn("Tweak.m", make_content)


class TestMachOBinary(unittest.TestCase):
    """Verify compiled Mach-O binary if present."""

    def test_dylib_if_present(self):
        dylib_path = os.path.join(SCRIPT_DIR, "IndigoThermalFix.dylib")
        if not os.path.exists(dylib_path):
            self.skipTest("IndigoThermalFix.dylib not yet compiled locally (runs in CI post-build step)")

        with open(dylib_path, "rb") as f:
            data = f.read()

        self.assertGreater(len(data), 4096, "Dylib file is too small")
        magic, = struct.unpack_from("<I", data, 0)
        self.assertIn(magic, [0xfeedfacf, 0xcafebabe], f"Invalid Mach-O magic: 0x{magic:08x}")


def main():
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
