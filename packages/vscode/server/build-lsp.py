from os import system
from shutil import which
import os.path
from glob import glob
import platform
from sys import argv

# Check for Cabal and XMake 
if not which('cabal'):
  print('Please install cabal')
  exit(1)

# Build the compiler project
system('cabal build')

ext = '.exe' if platform.system() == 'Windows' else ''

executable_name = f"bonzai-lsp{ext}"

found_executables = glob(f"dist-newstyle/**/{executable_name}", recursive=True)
executable_files = [file for file in found_executables if os.path.isfile(file)]

if len(executable_files) == 0:
  print('No executable found')
  exit(1)

executable = executable_files[0]
executable_out = f"bonzai-lsp{ext}"

BONZAI_BIN_PATH = os.path.join(os.environ.get('BONZAI_PATH', None), 'bin')


if not os.path.isdir(BONZAI_BIN_PATH): os.mkdir(BONZAI_BIN_PATH)

system(f"cp {executable} {BONZAI_BIN_PATH}/{executable_out}")