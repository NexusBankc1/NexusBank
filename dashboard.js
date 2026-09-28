import {supabase,money,formatDate,escapeHtml,profileIsActive,profileIsDeleted} from '../supabase.js';
import {accountFor,nav,logout,toast,wireHeaderBadge} from './common.js';
const $=id=>document.getElementById(id);
$('logoutBtn').onclick=logout;$('nav').innerHTML=nav('home');
async function init(){
 const {data:{session}}=await supabase.auth.getSession();if(!session)return location.replace('../login.html');
 const {data:p}=await supabase.from('profiles').select('*').eq('id',session.user.id).single();
 if(!p)return location.replace('../login.html');if(!profileIsActive(p)||profileIsDeleted(p))return location.replace('../unavailable.html');
 const a=await accountFor(session.user.id);if(!a){$('status').textContent='No account has been assigned yet.';return;}
 $('balance').textContent=money(a.balance,a.currency);$('currency').textContent=a.currency||'USD';$('accountNumber').textContent=a.account_number||'—';$('routing').textContent=a.routing_identifier||'—';
 const state=a.status==='frozen'?'Frozen — transfers are unavailable.':a.status==='pending'?'Pending — new transactions may remain pending.':'Active — normal operations available.';$('status').textContent=state;
 const {data:txs}=await supabase.from('transactions').select('*').eq('account_id',a.id).order('display_transaction_at',{ascending:false,nullsLast:false}).order('created_at',{ascending:false}).limit(8);
 let income=0,expenses=0;(txs||[]).forEach(t=>{if(['deposit','credit','received'].includes(t.type))income+=Number(t.amount||0);if(['transfer','withdrawal','debit','sent'].includes(t.type))expenses+=Number(t.amount||0)});
 $('income').textContent=money(income,a.currency);$('expenses').textContent=money(expenses,a.currency);$('savings').textContent=money(Math.max(Number(a.balance||0),0),a.currency);
 $('txBody').innerHTML=txs?.length?txs.map(t=>`<a class="list-item" href="pages/transactions.html#${t.id}"><div><strong>${escapeHtml(t.description||t.type||'Transaction')}</strong><div class="muted">${formatDate(t.display_transaction_at||t.created_at)}</div></div><div class="amount-col"><strong class="${['deposit','credit','received'].includes(t.type)?'positive':'negative'}">${['deposit','credit','received'].includes(t.type)?'+':'−'}${money(Math.abs(t.amount),t.currency||a.currency)}</strong><span class="status-pill ${t.status==='pending'?'pending':''}">${escapeHtml(t.status||'completed')}</span></div></a>`).join(''):'<div class="hint">No transactions yet.</div>';
 await wireHeaderBadge(session.user.id); supabase.channel(`nexus-live-toast-${session.user.id}`).on('postgres_changes',{event:'INSERT',schema:'public',table:'notifications',filter:`user_id=eq.${session.user.id}`},payload=>{const n=payload.new;if(n?.title) toast(n.title,n.message||'New NEXUS notification','success');}).subscribe();
}
init().catch(e=>{console.error(e);toast('Dashboard unavailable',e.message||'Please refresh.','error')});
