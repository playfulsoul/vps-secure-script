
const sections=[...document.querySelectorAll('main section')];
const search=document.getElementById('search');
search.addEventListener('input',()=>{const q=search.value.trim().toLowerCase();let n=0;sections.forEach(s=>{const show=!q||s.textContent.toLowerCase().includes(q);s.classList.toggle('hidden',!show);if(show)n++;});document.getElementById('count').textContent=q?'找到 '+n+' 个章节':'搜索按章节筛选';document.getElementById('empty').style.display=n?'none':'block';});
document.querySelectorAll('nav a').forEach(a=>a.addEventListener('click',()=>{search.value='';search.dispatchEvent(new Event('input'));}));
document.getElementById('print').addEventListener('click',()=>{search.value='';search.dispatchEvent(new Event('input'));window.print();});
let printDetails=[];
window.addEventListener('beforeprint',()=>{printDetails=[...document.querySelectorAll('details')].filter(d=>!d.open);printDetails.forEach(d=>d.open=true);});
window.addEventListener('afterprint',()=>{printDetails.forEach(d=>d.open=false);printDetails=[];});


