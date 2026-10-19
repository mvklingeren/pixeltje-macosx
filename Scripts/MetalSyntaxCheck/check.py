#!/usr/bin/env python3
# Syntax and type check of a GPU Program shader where Apple's Metal compiler is
# unavailable, for example in a Linux agent container.
#
# usage: Scripts/MetalSyntaxCheck/check.py <Shader.metal> [--rev <git revision>]
#
# The shader is read from Examples/, from the working tree or from a git
# revision. Like the engine, it gets the opt-in libraries its leading marker
# lines name (taken from the Swift sources) and one level of sibling
# #include "File.metal" expansion. Metal's vector constructors become OpenCL
# vector literals, and clang parses the result as C++ for OpenCL against the
# shim in include/metal_stdlib. Static asserts are evaluated, and the layout
# of float3, float4 and uint4 matches Metal's, so buffer-size asserts hold.
#
# A clean result is evidence, not a Metal build: Apple's compiler may still
# reject what this accepts. The shim covers the Signal Range, FPS 3D starter,
# Ashen Path, Flarefun, Flurry, Orbital Bloom and spinning triangle programs.
# Others still fail on dialect differences rather than bugs: Metal reads a
# bare 2.0 as float where OpenCL reads double, and Metal resolves some mixed
# scalar calls that OpenCL finds ambiguous. When adding shim coverage, first check that the
# shader's previous revision compiles cleanly here, so any remaining errors
# belong to the change. Needs python3, git and clang 18 or later.
import argparse
import os
import re
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.dirname(os.path.dirname(here))
parser = argparse.ArgumentParser()
parser.add_argument('shader', help='a .metal file name in Examples/')
parser.add_argument('--rev', help='git revision to read instead of the working tree')
arguments = parser.parse_args()


def read(path):
    if arguments.rev is None:
        with open(os.path.join(repo, path)) as file:
            return file.read()
    return subprocess.check_output(
        ['git', '-C', repo, 'show', f'{arguments.rev}:{path}']).decode()


def swift_library(name):
    with open(os.path.join(repo, 'Sources/PixeltjePipelineEngine', name)) as file:
        body = file.read().split('static let library = """\n', 1)[1]
    body = body.split('\n    """', 1)[0]
    return '\n'.join(line[4:] if line.startswith('    ') else line
        for line in body.split('\n'))


libraries = [
    ('// pixeltje:easing-v1', 'PipelineMetalEasing.swift'),
    ('// pixeltje:3d-v1', 'PipelineMetal3D.swift'),
    ('// pixeltje:terrain-v1', 'PipelineMetalTerrain.swift'),
]
lines = []
for line in read('Examples/' + arguments.shader).split('\n'):
    stripped = line.strip()
    lines.append(read('Examples/' + stripped[10:-1])
        if stripped.startswith('#include "') else line)
source = '\n'.join(lines)
markers = source.split('\n')[:len(libraries)]
source = '\n'.join(swift_library(file) for marker, file in libraries
    if marker in markers) + '\n' + source
# Program-scope constants must stay constant expressions for array sizes.
source = re.sub(r'(?m)^constant ', 'constexpr ', source).replace('metal::', '')
source = re.sub(r'\b((?:float|uint|int|uchar|short|ushort)[234])\(', r'(\1)(', source)

with tempfile.NamedTemporaryFile('w', suffix='.clcpp', delete=False) as file:
    file.write(source)
    resolved = file.name
result = subprocess.run(['clang', '-x', 'clcpp', '-cl-std=clc++2021',
    '-fsyntax-only', '-I', os.path.join(here, 'include'),
    '-Wno-unknown-attributes', '-Wno-c++11-narrowing', '-ferror-limit=50',
    resolved], capture_output=True, text=True)
sys.stderr.write(result.stderr)
print(f'{arguments.shader}: ' + ('clean' if result.returncode == 0
    else f'errors (resolved source kept at {resolved})'))
if result.returncode == 0:
    os.unlink(resolved)
sys.exit(result.returncode)
