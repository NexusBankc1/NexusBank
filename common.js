import {supabase,money,formatDate,escapeHtml,profileIsActive,profileIsDeleted} from '../supabase.js';
export const $=id=>document.getElementById(id);
export {money,formatDate,escapeHtml,supabase};

export async function requireUser(cb){
  const {data:{session}}=await supabase.auth.getSession();
  if(!session){location.replace('../login.html');return;}
  const {data:p}=await supabase.from('profiles').select('*').eq('id',session.user.id).single();
  if(!p){location.replace('../login.html');return;}
  if(!profileIsActive(p)||profileIsDeleted(p)){location.replace('../unavailable.html');return;}
  cb(session.user,p);
}
export async function logout(){await supabase.auth.signOut();location.replace('../login.html');}
export function nav(active){
 const items=[['home','Home','../dashboard.html','⌂'],['send','Transfer','send-money.html','↗'],['deposit','Deposit','add-money.html','＋'],['history','History','transactions.html','◷'],['cards','Cards','card.html','▣']];
 return `<nav class="bottom-nav">${items.map(x=>`<a class="${active===x[0]?'active':''}" href="${x[2]}"><div>${x[3]}</div>${x[1]}</a>`).join('')}</nav>`;
}
export function toast(title,message,type='error',opts={}){
 let wrap=document.querySelector('.toast-wrap');
 if(!wrap){wrap=document.createElement('div');wrap.className='toast-wrap';document.body.appendChild(wrap);}
 const el=document.createElement('div');el.className=`toast ${type}`;
 const href=opts.href||'support.html';
 el.innerHTML=`<div class="toast-icon">${type==='success'?'✓':type==='warning'?'!':'i'}</div><div style="flex:1"><strong>${escapeHtml(title)}</strong><p>${escapeHtml(message)}</p>${opts.support?`<a class="btn btn-light toast-support" href="${href}">Customer Care</a>`:''}</div><button class="btn btn-light toast-close" aria-label="Close">×</button>`;
 el.querySelector('.toast-close').onclick=()=>el.remove();
 wrap.appendChild(el);setTimeout(()=>el.remove(),9000);
}
export async function accountFor(userId){const {data,error}=await supabase.from('accounts').select('*').eq('user_id',userId).is('deleted_at',null).limit(1).maybeSingle();if(error)throw error;return data;}
export async function customerSettings(){const {data}=await supabase.from('platform_settings').select('customer_care_email,customer_care_whatsapp').eq('id',1).maybeSingle();return data||{customer_care_email:'support@example.com',customer_care_whatsapp:''};}
export async function unreadCount(userId){const {count}=await supabase.from('notifications').select('id',{count:'exact',head:true}).eq('user_id',userId).eq('is_read',false).eq('is_deleted',false);return count||0;}
export function injectHeader(title,subtitle='Online Banking',showNotifications=true){
 return `<header class="topbar"><div class="brand-block"><div class="brand-mark">N</div><div><div class="brand">NEXUS</div><small>${escapeHtml(subtitle)}</small></div></div><div class="topbar-actions">${showNotifications?`<a class="icon-btn" href="notifications.html" aria-label="Notifications">♧<span id="headerUnread" class="badge">0</span></a>`:''}<a class="icon-btn" href="support.html" aria-label="Customer Care">?</a><button id="logoutBtn" class="btn btn-danger">Sign out</button></div></header>`;
}
export async function wireHeaderBadge(userId){const e=document.getElementById('headerUnread');if(!e)return;const update=async()=>{e.textContent=await unreadCount(userId);e.hidden=Number(e.textContent)===0};await update();supabase.channel(`nexus-badge-${userId}`).on('postgres_changes',{event:'*',schema:'public',table:'notifications',filter:`user_id=eq.${userId}`},update).subscribe();}
