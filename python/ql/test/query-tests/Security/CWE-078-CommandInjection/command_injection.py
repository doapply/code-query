import re
import os
import subprocess

from flask import Flask, request
app = Flask(__name__)


@app.route("/command1")
def command_injection1():
    files = request.args.get('files', '')
    # Don't let files be `; rm -rf /`
    os.system("ls " + files) # $flow="ImportMember, l:-8 -> BinaryExpr"


@app.route("/command2")
def command_injection2():
    files = request.args.get('files', '')
    # Don't let files be `; rm -rf /`
    subprocess.Popen("ls " + files, shell=True) # $flow="ImportMember, l:-15 -> BinaryExpr"


@app.route("/command3")
def first_arg_injection():
    cmd = request.args.get('cmd', '')
    subprocess.Popen([cmd, "param1"]) # $flow="ImportMember, l:-21 -> cmd"


@app.route("/other_cases")
def others():
    files = request.args.get('files', '')
    # Don't let files be `; rm -rf /`
    os.popen("ls " + files) # $flow="ImportMember, l:-28 -> BinaryExpr"


@app.route("/multiple")
def multiple():
    command = request.args.get('command', '')
    # We should mark flow to both calls here, which conflicts with removing flow out of
    # a sink due to use-use flow.
    os.system(command) # $flow="ImportMember, l:-36 -> command"
    os.system(command) # $flow="ImportMember, l:-37 -> command"


@app.route("/not-into-sink-impl")
def not_into_sink_impl():
    """When there is flow to a sink such as `os.popen(cmd)`, we don't want to highlight that there is also
    flow through the actual `popen` function to the internal call to `subprocess.Popen` -- we would usually
    see that flow since we extract the `os.py` file from the standard library.

    os.popen implementation: https://github.com/python/cpython/blob/fa7ce080175f65d678a7d5756c94f82887fc9803/Lib/os.py#L974
    subprocess.call implementation: https://github.com/python/cpython/blob/fa7ce080175f65d678a7d5756c94f82887fc9803/Lib/subprocess.py#L341
    """
    command = request.args.get('command', '')
    os.system(command) # $flow="ImportMember, l:-50 -> command"
    os.popen(command) # $flow="ImportMember, l:-51 -> command"
    subprocess.call(command) # $flow="ImportMember, l:-52 -> command"
    subprocess.check_call(command) # $flow="ImportMember, l:-53 -> command"
    subprocess.run(command) # $flow="ImportMember, l:-54 -> command"


@app.route("/path-exists-not-sanitizer")
def path_exists_not_sanitizer():
    """os.path.exists is not a sanitizer

    This small example is inspired by real world code. Initially, it seems like a good
    sanitizer. However, if you are able to create files, you can make the
    `os.path.exists` check succeed, and still be able to run commands. An example is
    using the filename `not-there || echo pwned`.
    """
    path = request.args.get('path', '')
    if os.path.exists(path):
        os.system("ls " + path) # $flow="ImportMember, l:-68 -> BinaryExpr"


@app.route("/restricted-characters")
def restricted_characters():
    path = request.args.get('path', '')
    if re.match(r'^[a-zA-Z0-9_-]+$', path):
        os.system("ls " + path) # $SPURIOUS: flow="ImportMember, l:-75 -> BinaryExpr"
