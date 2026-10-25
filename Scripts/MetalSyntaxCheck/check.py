#!/usr/bin/env python3
# Syntax and type check of a GPU Program shader where Apple's Metal compiler is
# unavailable, for example in a Linux agent container.
#
# usage: Scripts/MetalSyntaxCheck/check.py <Shader.metal> [--rev <git revision>]
#
# The shader is read from Examples/, from the working tree or from a git
# revision. Like the engine, it gets the opt-in libraries its leading marker
# lines name (taken from the Swift sources) and recursive sibling
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
import posixpath
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
    ('// pixeltje:postfx-v1', 'PipelineMetalPostFX.swift'),
    ('// pixeltje:physics-v1', 'PipelineMetalPhysics.swift'),
]

active_stack = []
included_once = set()
include_count = 0


def valid_shader_name(name):
    return (name not in ('', '.', '..') and '/' not in name
            and '\\' not in name and name.endswith('.metal'))


def shader_source(name):
    if not valid_shader_name(name):
        raise RuntimeError('Metal includes must name a .metal file beside the workflow.')
    if arguments.rev is None:
        root = os.path.realpath(os.path.join(repo, 'Examples'))
        path = os.path.realpath(os.path.join(root, name))
        if os.path.dirname(path) != root or not os.path.isfile(path):
            raise RuntimeError(f'Metal source file {name} is outside Examples or missing.')
        if not 1 <= os.path.getsize(path) <= 4_194_304:
            raise RuntimeError('Metal source file must contain 1 to 4,194,304 UTF-8 bytes.')
        with open(path, 'rb') as file:
            data = file.read(4_194_305)
        identity = path
    else:
        canonical = name
        visited = set()
        while True:
            if canonical in visited:
                raise RuntimeError(f'Metal source file {name} has a symlink cycle.')
            visited.add(canonical)
            git_path = 'Examples/' + canonical
            entry = subprocess.check_output([
                'git', '-C', repo, 'ls-tree', '-z', arguments.rev,
                '--', ':(literal)' + git_path])
            if not entry:
                raise RuntimeError(f'Metal source file {name} is missing at {arguments.rev}.')
            mode = entry.split(b' ', 1)[0]
            data = subprocess.check_output([
                'git', '-C', repo, 'show', f'{arguments.rev}:{git_path}'])
            if mode != b'120000':
                if mode not in (b'100644', b'100755'):
                    raise RuntimeError(f'Metal source file {name} is not a regular file.')
                identity = git_path
                break
            target = data.decode('utf-8')
            target_path = posixpath.normpath(posixpath.join('Examples', target))
            if posixpath.dirname(target_path) != 'Examples':
                raise RuntimeError(f'Metal source file {name} links outside Examples.')
            canonical = posixpath.basename(target_path)
            if not valid_shader_name(canonical):
                raise RuntimeError(f'Metal source file {name} links to an invalid shader name.')
    if not 1 <= len(data) <= 4_194_304:
        raise RuntimeError('Metal source file must contain 1 to 4,194,304 UTF-8 bytes.')
    return data.decode('utf-8'), identity


def line_directive(number, name):
    escaped = ''.join('\\"' if char == '"' else '\\\\' if char == '\\'
        else f'\\{ord(char):03o}' if ord(char) < 32 or ord(char) == 127
        else char for char in name)
    return f'#line {number} "{escaped}"'


def expand(shader_name):
    global include_count
    if len(active_stack) > 16:
        raise RuntimeError('Metal local includes exceed the maximum nesting depth of 16.')
    source, identity = shader_source(shader_name)
    if identity in included_once:
        return ''
    if identity in active_stack:
        chain = ' -> '.join(posixpath.basename(path)
            for path in active_stack + [identity])
        raise RuntimeError(f'Metal local includes form a cycle: {chain}.')
    raw_lines = source.split('\n')
    if any(line.strip() == '#pragma once' for line in raw_lines):
        included_once.add(identity)
    active_stack.append(identity)
    out = [line_directive(1, shader_name)]
    for idx, line in enumerate(raw_lines, start=1):
        stripped = line.strip()
        if stripped == '#pragma once':
            out.append('')
        elif stripped.startswith('#include "') and stripped.endswith('"') and len(stripped) > 11:
            include_count += 1
            if include_count > 64:
                raise RuntimeError('Metal local includes exceed 64 expansions.')
            child = expand(stripped[10:-1])
            if child:
                out.append(child)
            out.append(line_directive(idx + 1, shader_name))
        else:
            out.append(line)
    active_stack.pop()
    expanded = '\n'.join(out)
    if len(expanded.encode('utf-8')) > 8_388_608:
        raise RuntimeError('Metal source and includes exceed 8,388,608 UTF-8 bytes.')
    return expanded


source = expand(arguments.shader)
markers = [line for line in source.split('\n')[:len(libraries) + 4]
           if not line.startswith('#line ')]
selected_libraries = [swift_library(file) for marker, file in libraries
                      if marker in markers]
if selected_libraries:
    source = '\n'.join(selected_libraries) + '\n#line 1\n' + source
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
