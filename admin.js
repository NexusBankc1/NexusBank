import {supabase,invokeAdminFunction,money,formatDate,escapeHtml,profileIsActive,profileIsDeleted} from './supabase.js';
const $=id=>document.getElementById(id);let profiles=[],accounts=[],transactions=[];
function msg(id,text,type=''){const e=$(id);e.style.display='block';e.className=`notice ${type?'notice-'+type:''}`;e.textContent=text}
async function guard(){
  let session=null;
  let lastError=null;

  // First try the persisted session. If Android/TrebEdit has not restored it
  // yet, give Supabase time to restore/refresh it before redirecting.
  for(let attempt=0;attempt<16;attempt++){
    try{
      const {data,error}=await supabase.auth.getSession();
      if(error)throw error;
      session=data?.session||null;
      if(session)break;
    }catch(e){ lastError=e; }
    await new Promise(resolve=>setTimeout(resolve,250));
  }

  if(!session){
    try{
      const {data,error}=await supabase.auth.refreshSession();
      if(error)throw error;
      session=data?.session||null;
    }catch(e){ lastError=e; }
  }

  if(!session){
    try{
      const {data,error}=await supabase.auth.getUser();
      if(error)throw error;
      if(data?.user){
        const restored=await supabase.auth.getSession();
        session=restored.data?.session||null;
      }
    }catch(e){ lastError=e; }
  }

  if(!session){
    console.error('[NEXUS admin guard] No active session after restore attempts.',lastError);
    location.replace('login.html?error=session');
    return null;
  }

  const {data:rows,error}=await supabase.rpc('nexus_get_my_profile');
  if(error)throw error;
  const p=Array.isArray(rows)?rows[0]:rows;
  if(!p)throw new Error('NEXUS administrator profile could not be loaded.');
  if(!['admin','super_admin'].includes(p.role)){
    location.replace('dashboard.html');
    return null;
  }
  if(!profileIsActive(p)||profileIsDeleted(p)){
    location.replace('unavailable.html');
    return null;
  }
  return p;
}

async function load(){
 const [{data:p},{data:a},{data:tx},{data:care},{data:rec},{data:depPending,count:dp},{data:wdPending,count:wp},{data:depDone,count:dd},{data:wdDone,count:wd},{data:wdRows},{data:aud}]=await Promise.all([
  supabase.from('profiles').select('*').order('created_at',{ascending:false}),supabase.from('accounts').select('*').order('created_at',{ascending:false}),supabase.from('transactions').select('*').order('created_at',{ascending:false}).limit(150),supabase.from('platform_settings').select('*').eq('id',1).maybeSingle(),supabase.from('recipient_accounts').select('*').order('created_at',{ascending:false}).limit(100),
  supabase.from('deposits').select('id',{count:'exact',head:true}).eq('status','pending'),supabase.from('withdrawals').select('id',{count:'exact',head:true}).eq('status','pending'),supabase.from('deposits').select('id',{count:'exact',head:true}).eq('status','completed'),supabase.from('withdrawals').select('id',{count:'exact',head:true}).eq('status','completed'),supabase.from('withdrawals').select('*').eq('status','pending').order('created_at',{ascending:false}).limit(50),supabase.from('audit_logs').select('*').order('created_at',{ascending:false}).limit(80)
 ]);
 profiles=p||[];accounts=a||[];transactions=tx||[];
 $('customers').textContent=profiles.filter(x=>x.role==='customer'&&!profileIsDeleted(x)).length;$('accounts').textContent=accounts.filter(x=>!x.deleted_at).length;$('frozen').textContent=accounts.filter(x=>x.status==='frozen'&&!x.deleted_at).length;$('pending').textContent=accounts.filter(x=>x.status==='pending'&&!x.deleted_at).length;
 $('pendingDeposits').textContent=dp||0;$('pendingWithdrawals').textContent=wp||0;$('completedDeposits').textContent=dd||0;$('completedWithdrawals').textContent=wd||0;
 $('careEmail').value=care?.customer_care_email||'';$('careWhatsapp').value=care?.customer_care_whatsapp||'';
 renderUsers();renderTransactions();renderRecycle();renderRecipients(rec||[]);renderWithdrawals(wdRows||[]);renderAudit(aud||[]);
}
function renderUsers(){const q=($('userSearch').value||'').toLowerCase();const rows=accounts.filter(a=>{const p=profiles.find(x=>x.id===a.user_id)||{};return !q||[p.full_name,p.email,a.account_number,a.id].join(' ').toLowerCase().includes(q)});$('users').innerHTML=rows.length?`<table class="table"><thead><tr><th>Customer</th><th>Account</th><th>Balance</th><th>Status</th><th>Actions</th></tr></thead><tbody>${rows.map(a=>{const p=profiles.find(x=>x.id===a.user_id)||{};const status=!profileIsActive(p)?'deactivated':profileIsDeleted(p)?'deleted':a.status||'active';return `<tr><td><strong>${escapeHtml(p.full_name||'—')}</strong><br><span class="muted">${escapeHtml(p.email||'')}</span></td><td>${escapeHtml(a.account_number||'—')}<br><span class="muted">${escapeHtml(a.id)}</span></td><td>${money(a.balance,a.currency)}</td><td><span class="status-pill ${status==='frozen'||status==='deactivated'?'frozen':status==='pending'?'pending':status==='deleted'?'deleted':''}">${escapeHtml(status)}</span></td><td><div class="admin-actions"><button class="btn btn-light" data-action="active" data-id="${a.id}">Active</button><button class="btn btn-warning" data-action="pending" data-id="${a.id}">Pending</button><button class="btn btn-danger" data-action="frozen" data-id="${a.id}">Freeze</button><button class="btn btn-success" data-action="active" data-id="${a.id}">Unfreeze</button><button class="btn btn-light" data-action="deactivate" data-id="${a.id}">Deactivate</button><button class="btn btn-success" data-action="reactivate" data-id="${a.id}">Reactivate</button><button class="btn btn-danger" data-action="delete" data-id="${a.id}">Delete</button></div></td></tr>`}).join('')}</tbody></table>`:'<div class="hint">No accounts found.</div>';document.querySelectorAll('[data-action]').forEach(b=>b.onclick=()=>accountAction(b.dataset.id,b.dataset.action))}
async function accountAction(id,action){try{if(action==='delete'&&!confirm('Move this account to the Recycle Bin?'))return;let result;if(action==='delete')result=await invokeAdminFunction('soft_delete_account',{account_id:id});else if(action==='deactivate')result=await invokeAdminFunction('deactivate_account',{account_id:id});else if(action==='reactivate')result=await invokeAdminFunction('reactivate_account',{account_id:id});else result=await invokeAdminFunction('set_account_status',{account_id:id,status:action});if(result?.error)throw Error(result.error);await load()}catch(e){alert(e.message||'Action failed')}}
function renderTransactions(){$('txTable').innerHTML=transactions.length?`<table class="table"><thead><tr><th>Reference</th><th>User</th><th>Type</th><th>Amount</th><th>Status</th><th>Original</th><th>Display</th><th>Action</th></tr></thead><tbody>${transactions.map(t=>`<tr><td>${escapeHtml(t.reference||t.id)}</td><td>${escapeHtml(profiles.find(x=>x.id===t.user_id)?.email||'')}</td><td>${escapeHtml(t.type||'')}</td><td>${money(Math.abs(t.amount),t.currency)}</td><td>${escapeHtml(t.status||'')}</td><td>${formatDate(t.created_at)}</td><td>${formatDate(t.display_transaction_at||t.created_at)}</td><td><button class="btn btn-light" data-tx="${t.id}">Edit date</button></td></tr>`).join('')}</tbody></table>`:'<div class="hint">No transactions found.</div>';document.querySelectorAll('[data-tx]').forEach(b=>b.onclick=()=>{$('txId').value=b.dataset.tx;$('txDate').focus()})}
function renderRecycle(){const deleted=profiles.filter(x=>profileIsDeleted(x));$('recycle').innerHTML=deleted.length?`<table class="table"><thead><tr><th>User</th><th>Email</th><th>Deleted</th><th>Action</th></tr></thead><tbody>${deleted.map(p=>`<tr><td>${escapeHtml(p.full_name||'')}</td><td>${escapeHtml(p.email||'')}</td><td>${formatDate(p.deleted_at)}</td><td><button class="btn btn-success" data-restore="${p.id}">Restore</button></td></tr>`).join('')}</tbody></table>`:'<div class="hint">Recycle Bin is empty.</div>';document.querySelectorAll('[data-restore]').forEach(b=>b.onclick=async()=>{try{await invokeAdminFunction('restore_account',{user_id:b.dataset.restore});await load()}catch(e){alert(e.message)}})}
function renderRecipients(list){$('recipientTable').innerHTML=list.length?`<table class="table"><thead><tr><th>Account</th><th>Name</th><th>Bank</th><th>Status</th><th>Created</th></tr></thead><tbody>${list.map(r=>`<tr><td>${escapeHtml(r.account_number)}</td><td>${escapeHtml(r.account_name)}</td><td>${escapeHtml(r.bank_name)}</td><td>${escapeHtml(r.status)}</td><td>${formatDate(r.created_at)}</td></tr>`).join('')}</tbody></table>`:'<div class="hint">No generated recipient accounts yet.</div>'}
function renderWithdrawals(list){$('withdrawalsTable').innerHTML=list.length?`<table class="table"><thead><tr><th>User</th><th>Amount</th><th>Destination</th><th>Created</th><th>Status</th></tr></thead><tbody>${list.map(w=>`<tr><td>${escapeHtml(profiles.find(p=>p.id===w.user_id)?.email||w.user_id)}</td><td>${money(w.amount,w.currency)}</td><td>${escapeHtml(w.destination)}</td><td>${formatDate(w.created_at)}</td><td><span class="status-pill pending">pending</span></td></tr>`).join('')}</tbody></table>`:'<div class="hint">No pending withdrawals.</div>'}
function renderAudit(list){$('auditTable').innerHTML=list.length?`<table class="table"><thead><tr><th>Action</th><th>Admin</th><th>Target</th><th>Date</th></tr></thead><tbody>${list.map(x=>`<tr><td>${escapeHtml(x.action)}</td><td>${escapeHtml(x.admin_user_id||'')}</td><td>${escapeHtml(x.target_user_id||'')}</td><td>${formatDate(x.created_at)}</td></tr>`).join('')}</tbody></table>`:'<div class="hint">No audit records yet.</div>'}
$('refresh').onclick=load;$('logout').onclick=async()=>{await supabase.auth.signOut();location.replace('login.html')};$('userSearch').oninput=renderUsers;
$('create').onclick=async()=>{const payload={full_name:$('name').value.trim(),email:$('email').value.trim(),password:$('password').value,phone:$('phone').value.trim(),currency:$('currency').value,transaction_pin:$('pin').value.trim()};try{const d=await invokeAdminFunction('create_customer',payload);msg('createMsg',`Customer created. Account number: ${d.account_number}`,'ok');['name','email','password','phone','pin'].forEach(x=>$(x).value='');await load()}catch(e){msg('createMsg',e.message||'Customer creation failed','error')}};
$('fundBtn').onclick=async()=>{try{const d=await invokeAdminFunction('fund_account',{account_id:$('fundAccount').value.trim(),amount:Number($('fundAmount').value),note:$('fundNote').value.trim()});msg('fundMsg',`Funds added. New balance: ${money(d.new_balance,'')}`,'ok');$('fundAmount').value='';$('fundNote').value='';await load()}catch(e){msg('fundMsg',e.message,'error')}};
$('createRecipient').onclick=async()=>{try{await invokeAdminFunction('create_recipient_account',{account_number:$('recipientNumber').value.trim(),account_name:$('recipientName').value.trim(),bank_name:$('recipientBank').value.trim()});msg('recipientMsg','Recipient account created.','ok');['recipientNumber','recipientName','recipientBank'].forEach(x=>$(x).value='');await load()}catch(e){msg('recipientMsg',e.message,'error')}};
$('saveCare').onclick=async()=>{try{await invokeAdminFunction('update_customer_care',{email:$('careEmail').value.trim(),whatsapp:$('careWhatsapp').value.trim()});msg('careMsg','Customer Care settings saved.','ok')}catch(e){msg('careMsg',e.message,'error')}};
$('saveTxDate').onclick=async()=>{try{const value=$('txDate').value;if(!value)throw Error('Choose a date and time.');await invokeAdminFunction('update_transaction_date',{transaction_id:$('txId').value.trim(),display_transaction_at:new Date(value).toISOString()});msg('txMsg','Transaction display date updated and audit logged.','ok');await load()}catch(e){msg('txMsg',e.message,'error')}};
$('saveWalletBtn').onclick=async()=>{try{await invokeAdminFunction('save_crypto_wallet',{account_id:$('walletAccount').value.trim(),asset:$('walletAsset').value,network:$('walletNetwork').value,address:$('walletAddress').value.trim(),label:$('walletLabel').value.trim()});msg('walletResult','Crypto wallet saved.','ok');$('walletAddress').value='';$('walletLabel').value=''}catch(e){msg('walletResult',e.message,'error')}};
$('cryptoDepositBtn').onclick=async()=>{try{const d=await invokeAdminFunction('credit_crypto',{account_id:$('cryptoDepositAccount').value.trim(),asset:$('cryptoDepositAsset').value,network:$('cryptoDepositNetwork').value,amount:Number($('cryptoDepositAmount').value),note:$('cryptoDepositNote').value.trim(),reference:$('cryptoDepositTxHash').value.trim()||null});msg('cryptoDepositResult',`Crypto credited successfully. New crypto balance: ${d.new_balance} ${$('cryptoDepositAsset').value}. Reference: ${d.reference}`,'ok');$('cryptoDepositAmount').value='';$('cryptoDepositTxHash').value='';$('cryptoDepositNote').value='';await load()}catch(e){msg('cryptoDepositResult',e.message,'error')}};
$('walletAsset').onchange=()=>{const a=$('walletAsset').value,n=$('walletNetwork');[...n.options].forEach(o=>o.hidden=a==='BTC'?o.value!=='BTC':o.value==='BTC');n.value=a==='BTC'?'BTC':'TRC20'};$('cryptoDepositAsset').onchange=()=>{const a=$('cryptoDepositAsset').value,n=$('cryptoDepositNetwork');[...n.options].forEach(o=>o.hidden=a==='BTC'?o.value!=='BTC':o.value==='BTC');n.value=a==='BTC'?'BTC':'TRC20'};
guard().then(p=>{if(p) return load();}).catch(e=>{console.error('[NEXUS admin]',e); const el=document.getElementById('users'); if(el) el.textContent='Unable to load the administrator dashboard. Please refresh and try again.';});
