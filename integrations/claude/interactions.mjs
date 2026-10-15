// Provider protocol mapping. Prompt text and offered answers remain runtime data.
import { randomUUID } from 'node:crypto';
import { invalid } from './shared/bridge.mjs';
export class HookInteractions {
    pending = new Map();
    get views() { return [...this.pending.values()].map(p => p.view); }
    open(event, signal) {
        const input = event.tool_input ?? {};
        const questions = event.hook_event_name === 'PreToolUse' && event.tool_name === 'AskUserQuestion' && Array.isArray(input.questions) ? input.questions : null;
        if (!questions && event.hook_event_name !== 'PermissionRequest') return {};
        if (this.pending.size >= 16) return {}; // retain the original local flow
        const id = 'hook-' + randomUUID();
        const normalized = questions?.map((q,i)=>({id:String(i),title:q.header ?? '',prompt:q.question,
            options:(q.options ?? []).map(o=>({label:o.label,description:o.description ?? ''})),multiple:q.multiSelect === true,other:true,secret:false}));
        if (questions && (!questions.length || questions.length > 8 || normalized.some(q=>typeof q.prompt !== 'string' || q.options.some(o=>typeof o.label !== 'string')))) return {};
        const view = {id,title:questions ? '需要你的回答' : `允许 ${event.tool_name}？`,detail:questions ? '' : JSON.stringify(input,null,2),kind:questions ? 'questions' : 'confirm',options:[],questions:normalized ?? []};
        return new Promise(resolve=>{
            const finish = result=>{ clearTimeout(timer); this.pending.delete(id); signal?.removeEventListener('abort',cancel); resolve(result); };
            const cancel = ()=>finish({});
            const timer = setTimeout(cancel,240000);
            this.pending.set(id,{view,event,input,finish});
            signal?.addEventListener('abort',cancel,{once:true});
            if(signal?.aborted) cancel();
        });
    }
    answer(action) {
        const pending = this.pending.get(action.request_id);
        if (!pending) return false;
        const {event,input,view,finish} = pending;
        if (view.kind === 'questions') {
            const answers={};
            if(action.approved === true) {
                for(const q of view.questions) {
                    const values=action.answers?.[q.id];
                    if(!Array.isArray(values) || !values.length || (!q.multiple && values.length!==1) || values.some(v=>typeof v !== 'string' || !v.trim() || v.length>8192)) throw invalid('请完整回答当前问题。',400);
                    answers[q.prompt]=values.join(', ');
                }
            }
            finish({hookSpecificOutput:{hookEventName:'PreToolUse',permissionDecision:action.approved === true?'allow':'deny',...(action.approved === true ? {updatedInput:{...input,answers}} : {permissionDecisionReason:'Cancelled by the user in AgentMux'})}});
        } else {
            finish({hookSpecificOutput:{hookEventName:'PermissionRequest',decision:{behavior:action.approved === true?'allow':'deny',...(action.approved === true?{}:{message:'Denied by the user in AgentMux'})}}});
        }
        return true;
    }
    close() { for(const p of this.pending.values()) p.finish({}); }
}
