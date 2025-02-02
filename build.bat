@echo off

setlocal
set name=bubble_jam

for %%a in (%*) do set "%%a=1"

if not "%release%" == "1" set debug=1

if not exist build mkdir build
pushd build

REM manually specifying what to vet because I don't want -vet-unused-stmt, which is included in -vet

if "%debug%" == "1" (
    if exist %name%.pdb del %name%.pdb
    odin build ..\src -debug -vet-unused -vet-unused-variables -vet-unused-imports -vet-shadowing -out:%name%.exe
) else (
    odin build ..\src -o:speed -out:%name%.exe
)

popd
