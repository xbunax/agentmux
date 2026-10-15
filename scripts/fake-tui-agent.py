#!/usr/bin/env python3
"""Interactive Agent fixture for an existing tmux pane. Never calls a model."""
import json
import os
import select
import sys
import termios
import tty
from pathlib import Path

provider, destination = sys.argv[1:]
events = Path(destination)
fd = sys.stdin.fileno()
previous = termios.tcgetattr(fd)
tty.setraw(fd)
draft, pending, mode, selected = '', '', 'editor', 0

def record(kind, **values):
    with events.open('a') as output:
        output.write(json.dumps({'kind':kind, 'provider':provider, 'pid':os.getpid(), **values})+'\n')

def render():
    if mode in ['model','approval']:
        choices = ['Model A','Model B','Model C'] if mode=='model' else ['Allow once','Deny']
        title = 'Choose model' if mode=='model' else 'Approve writing the fixture file?'
        text='\x1b[2J\x1b[H\x1b[?25l'+('────────────────────────────────────────\r\n' if provider=='pi' else '')+title+'\r\n\r\n'
        for index,label in enumerate(choices):
            text+=(('→ ' if provider=='pi' else '› ') if index==selected else '  ')+(label if provider=='pi' else f'{index+1}. {label}')+'\r\n'
        text+='\r\nenter to select · esc to cancel' if provider=='pi' else 'Enter to confirm · Esc to cancel'
        if provider=='pi': text+='\r\n────────────────────────────────────────'
    elif mode=='busy': text='\x1b[2J\x1b[H\x1b[?25lWorking · Esc to cancel'
    elif provider=='pi':
        border='────────────────────────────────────────'
        text='\x1b[2J\x1b[H\x1b[?25h'+border+'\r\n'+(draft if draft else '\x1b[2mType a message\x1b[0m')+'\r\n'+border[:-8]+'\x1b[7m INSERT\x1b[0m\x1b[2;'+str(len(draft)+1)+'H'
    elif provider=='claude':
        border='────────────────────────────────────────'
        text='\x1b[2J\x1b[H\x1b[?25l'+border+'\r\n❯\u00a0'+(draft if draft else '\x1b[2mAsk anything\x1b[0m')+'\r\n'+border+'\r\n-- INSERT --\x1b[2;'+str(len(draft)+3)+'H'
    else:
        prompt='›' if provider=='codex' else '❯'
        text='\x1b[2J\x1b[H\x1b[?25h'+prompt+' '+(draft if draft else '\x1b[2mAsk anything\x1b[0m')+'\x1b['+str(len(draft)+3)+'G'
    sys.stdout.write(text); sys.stdout.flush()

render()
try:
    while True:
        pending += os.read(fd,4096).decode('utf8',errors='replace')
        while pending:
            if pending.startswith(('\x1b[200~','\x1b[201~')):
                pending=pending[6:];continue
            if pending.startswith('\x1b['):
                if len(pending)<3: break
                if pending[2] in ['A','B']:
                    if mode in ['model','approval']:
                        selected=(selected+(1 if pending[2]=='B' else -1))%(3 if mode=='model' else 2)
                    pending=pending[3:]; render();continue
                if not any(c.isalpha() or c=='~' for c in pending[2:]): break
            char,pending=pending[0],pending[1:]
            if char=='\x04': sys.exit(0)
            if char=='\x1b':
                if not pending and select.select([fd],[],[],.02)[0]: pending=char+os.read(fd,4096).decode();continue
                if mode=='busy': record('abort')
                mode='editor';draft='';render();continue
            if char=='\x15': draft='';render();continue
            if char in ['\r','\n']:
                if mode=='model': record('model',value=['Model A','Model B','Model C'][selected]);mode='editor'
                elif mode=='approval':
                    record('approval',approved=selected==0)
                    if selected==0: events.with_suffix('.approved').write_text('approved by mobile confirmation')
                    mode='editor'
                elif mode=='editor':
                    record('message',text=draft)
                    if draft=='/model': mode='model';selected=0
                    elif draft=='/ask': mode='approval';selected=0
                    elif draft=='work': mode='busy'
                draft='';render();continue
            if mode=='editor' and char.isprintable(): draft+=char;render()
finally:
    termios.tcsetattr(fd,termios.TCSADRAIN,previous)
