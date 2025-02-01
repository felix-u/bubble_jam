@echo off

setlocal
set name=bubble_jam

if not exist build mkdir build
pushd build

REM manually specifying what to vet because I don't want -vet-unused-stmt, which is included in -vet
odin build ..\src -debug -vet-unused -vet-unused-variables -vet-unused-imports -vet-shadowing -out:%name%.exe

popd
