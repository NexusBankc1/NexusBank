import {supabase,profileFor,profileIsActive,profileIsDeleted} from './supabase.js';
const page=document.body.dataset.page;
const {data:{subscription}}=supabase.auth.onAuthStateChange(async(_e,session)=>{
 if(!session){location.replace('login.html');return}
 const p=await profileFor(session.user.id).catch(()=>null);
 if(!p){location.replace('login.html');return}
 if(!profileIsActive(p)||profileIsDeleted(p)){location.replace('unavailable.html');return}
 if(page==='admin'&&p.role!=='admin'){location.replace('dashboard.html');return}
 if(page==='customer'&&p.role==='admin'){location.replace('admin.html');return}
 document.querySelectorAll('[data-user-email]').forEach(e=>e.textContent=session.user.email||'');
 document.documentElement.classList.add('app-ready');
});
window.addEventListener('beforeunload',()=>subscription.unsubscribe());
