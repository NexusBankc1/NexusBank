import {supabase,money,formatDate,escapeHtml} from '../supabase.js';
import {requireUser,logout,$,nav,toast,accountFor} from './common.js';

$('logoutBtn').onclick=logout;
$('nav').innerHTML=nav('send');

let user,account,recipient;
let activeTransferRequestId=localStorage.getItem('nexus_active_transfer_request_id')||null;
let otpBusy=false;
let lookupTimer;

function showRecipient(t){
  $('recipientBox').hidden=false;
  $('recipientBox').className=`notice ${t.ok?'notice-ok':'notice-error'}`;
  $('recipientBox').innerHTML=t.html;
}

function saveActiveTransfer(id){
  activeTransferRequestId=id;
  if(id)localStorage.setItem('nexus_active_transfer_request_id',id);
  else localStorage.removeItem('nexus_active_transfer_request_id');
}

function clearActiveTransfer(){
  activeTransferRequestId=null;
  localStorage.removeItem('nexus_active_transfer_request_id');
}

async function load(){
  account=await accountFor(user.id);
  if(!account)throw Error('No NEXUS account was found.');
  $('currency').textContent=account.currency||'USD';
  $('balance').textContent=money(account.balance,account.currency);

  if(account.status==='frozen'){
    toast('Transfer unavailable','This account is frozen. You cannot make a transfer at this moment. Kindly contact Customer Care for further information and support.','error',{href:'support.html',support:true});
  }
  if(account.status==='pending'){
    toast('Transaction pending','This account is currently pending. New transfers can remain pending until the account is active.','warning',{href:'support.html',support:true});
  }

  await restorePendingTransfer();
}

async function lookup(){
  clearTimeout(lookupTimer);
  const n=$('recipient').value.trim();
  if(n.length<4){
    $('recipientBox').hidden=true;
    recipient=null;
    return;
  }

  lookupTimer=setTimeout(async()=>{
    const {data:r,error}=await supabase
      .from('recipient_accounts')
      .select('account_number,account_name,bank_name,status')
      .eq('account_number',n)
      .maybeSingle();

    if(error){
      recipient=null;
      showRecipient({ok:false,html:'<strong>Unable to verify account</strong><br>Please try again in a moment.'});
      return;
    }

    if(!r||r.status!=='active'){
      recipient=null;
      showRecipient({ok:false,html:'<strong>Account not found</strong><br>Please check the account number and try again.'});
      return;
    }

    recipient=r;
    showRecipient({
      ok:true,
      html:`<strong>${escapeHtml(r.account_name)}</strong><br>${escapeHtml(r.bank_name)}<br>Account ${escapeHtml(r.account_number)}`
    });
  },300);
}

async function requestOtp(){
  if(!activeTransferRequestId)throw Error('No active transfer request was found.');

  const {data:sent,error:sendError}=await supabase.functions.invoke('nexus-transfer-otp',{
    body:{transfer_request_id:activeTransferRequestId}
  });

  if(sendError)throw sendError;
  if(!sent?.success)throw Error(sent?.error||'The OTP could not be sent.');
  return sent;
}

function openOtpModal(message=''){
  $('otpMsg').style.display=message?'block':'none';
  if(message){
    $('otpMsg').className='notice notice-error';
    $('otpMsg').textContent=message;
  }
  $('otpModal').classList.add('show');
  $('otp').focus();
}

async function restorePendingTransfer(){
  if(!activeTransferRequestId)return;

  const {data:req,error}=await supabase
    .from('transfer_requests')
    .select('id,recipient_account_number,recipient_name,recipient_bank,amount,currency,reference,status,expires_at')
    .eq('id',activeTransferRequestId)
    .eq('user_id',user.id)
    .maybeSingle();

  if(error||!req){
    clearActiveTransfer();
    return;
  }

  if(req.status!=='awaiting_otp'||new Date(req.expires_at).getTime()<=Date.now()){
    clearActiveTransfer();
    if(req.status==='awaiting_otp'){
      toast('Transfer expired','The previous transfer verification request has expired. Please start the transfer again.','warning');
    }
    return;
  }

  recipient={
    account_number:req.recipient_account_number,
    account_name:req.recipient_name,
    bank_name:req.recipient_bank,
    status:'active'
  };
  $('recipient').value=req.recipient_account_number;
  $('amount').value=req.amount;
  $('reference').value=req.reference||'';
  $('currency').textContent=req.currency||account.currency||'USD';
  showRecipient({
    ok:true,
    html:`<strong>${escapeHtml(req.recipient_name)}</strong><br>${escapeHtml(req.recipient_bank)}<br>Account ${escapeHtml(req.recipient_account_number)}`
  });

  openOtpModal('Your transfer is still awaiting OTP verification. Enter the code sent to your registered email.');
}

$('recipient').addEventListener('input',lookup);

$('form').onsubmit=e=>{
  e.preventDefault();
  if(activeTransferRequestId)return openOtpModal('You already have a transfer awaiting OTP verification.');
  if(!recipient)return toast('Recipient required','Enter a valid account number and wait for the recipient details to appear.','error');

  const amount=Number($('amount').value);
  if(!amount||amount<=0)return toast('Invalid amount','Enter a valid transfer amount.','error');
  if(amount>Number(account.balance||0))return toast('Insufficient balance','The transfer amount is greater than your available balance.','error');
  if(account.status==='frozen')return toast('Transfer unavailable','This account is frozen. You cannot make a transfer at this moment. Kindly contact Customer Care.','error',{href:'support.html',support:true});

  $('pinModal').classList.add('show');
  $('pin').focus();
};

$('cancelPin').onclick=()=>{
  $('pinModal').classList.remove('show');
  $('pin').value='';
};

$('confirmBtn').onclick=async()=>{
  const pin=$('pin').value.trim();
  if(!/^\d{4,6}$/.test(pin))return toast('PIN required','Enter your 4–6 digit transaction PIN.','error');

  $('confirmBtn').disabled=true;
  try{
    const {data,error}=await supabase.rpc('create_transfer_request',{
      p_recipient_account_number:recipient.account_number,
      p_amount:Number($('amount').value),
      p_reference:$('reference').value.trim()||null,
      p_pin:pin
    });

    if(error)throw error;
    if(!data?.success)throw Error(data?.message||'Transfer request could not be created.');

    saveActiveTransfer(data.transfer_request_id);
    $('pinModal').classList.remove('show');
    $('otp').value='';
    openOtpModal('');

    try{
      await requestOtp();
    }catch(emailError){
      try{await supabase.rpc('cancel_transfer_request',{p_transfer_request_id:activeTransferRequestId});}catch(_e){}
      clearActiveTransfer();
      $('otpModal').classList.remove('show');
      throw emailError;
    }
  }catch(e){
    $('pinModal').classList.remove('show');
    const m=e.message||'Transfer request failed';
    if(/frozen/i.test(m))toast('Transfer unavailable','This account is frozen. You cannot make a transfer at this moment. Kindly contact Customer Care for further information and support.','error',{href:'support.html',support:true});
    else if(/pending/i.test(m))toast('Transaction pending','Your transaction is pending because this account is currently pending.','warning',{href:'support.html',support:true});
    else toast('Transfer failed',m,'error');
  }finally{
    $('confirmBtn').disabled=false;
  }
};

$('cancelOtp').onclick=async()=>{
  if(!activeTransferRequestId){
    $('otpModal').classList.remove('show');
    return;
  }

  try{
    await supabase.rpc('cancel_transfer_request',{p_transfer_request_id:activeTransferRequestId});
  }catch(_e){}

  clearActiveTransfer();
  $('otpModal').classList.remove('show');
  $('otp').value='';
};

$('verifyOtpBtn').onclick=async()=>{
  if(!activeTransferRequestId)return toast('Transfer unavailable','There is no active transfer awaiting verification.','error');

  const otp=$('otp').value.trim();
  if(!/^\d{6}$/.test(otp)){
    $('otpMsg').style.display='block';
    $('otpMsg').className='notice notice-error';
    $('otpMsg').textContent='Enter the 6-digit OTP code.';
    return;
  }

  if(otpBusy)return;
  otpBusy=true;
  $('verifyOtpBtn').disabled=true;
  $('otpMsg').style.display='none';
  $('otpModal').classList.remove('show');
  $('processModal').classList.add('show');

  try{
    const {data,error}=await supabase.rpc('verify_transfer_otp',{
      p_transfer_request_id:activeTransferRequestId,
      p_otp:otp
    });

    if(error)throw error;
    if(!data?.success)throw Error(data?.message||'OTP verification failed.');

    const t=data.transaction;
    const pending=t.status==='pending';

    $('processModal').classList.remove('show');
    $('receipt').innerHTML=`<div class="receipt"><div style="text-align:center"><div class="status-pill ${pending?'pending':''}">${pending?'Pending':'Successful'}</div><h2>NEXUS Transaction Receipt</h2></div><div class="receipt-row"><span>Recipient</span><strong>${escapeHtml(recipient.account_name)}</strong></div><div class="receipt-row"><span>Bank</span><strong>${escapeHtml(recipient.bank_name)}</strong></div><div class="receipt-row"><span>Account</span><strong>${escapeHtml(recipient.account_number)}</strong></div><div class="receipt-row"><span>Amount</span><strong>${money(t.amount,t.currency)}</strong></div><div class="receipt-row"><span>Status</span><strong>${escapeHtml(t.status)}</strong></div><div class="receipt-row"><span>Reference</span><strong>${escapeHtml(t.reference||t.id)}</strong></div><div class="receipt-row"><span>Date</span><strong>${formatDate(t.display_transaction_at||t.created_at)}</strong></div></div>`;
    $('receiptModal').classList.add('show');

    clearActiveTransfer();
    $('amount').value='';
    $('reference').value='';
    $('pin').value='';
    $('otp').value='';
    await load();
  }catch(e){
    $('processModal').classList.remove('show');
    const m=e.message||'OTP verification failed';
    if(/expired/i.test(m)||/OTP/i.test(m)){
      openOtpModal(m);
    }else{
      clearActiveTransfer();
      toast('Transfer failed',m,'error');
    }
  }finally{
    otpBusy=false;
    $('verifyOtpBtn').disabled=false;
  }
};

$('closeReceipt').onclick=()=>$('receiptModal').classList.remove('show');

requireUser(async(u)=>{
  user=u;
  try{
    await load();
  }catch(e){
    toast('Unable to load Send Money',e.message||'Please try again.','error');
  }
});
