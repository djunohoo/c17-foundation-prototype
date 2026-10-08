[CmdletBinding()]
param([string]$Root='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Version='0.1.0-implementation'
$GoVersion='go1.27.1'
$Run=$null
$Steps=New-Object System.Collections.Generic.List[object]
$Rules=New-Object System.Collections.Generic.List[string]
$Utf8=New-Object System.Text.UTF8Encoding($false)
$Status='BLOCKED';$Failure='';$Go=$null
$TestCount=0
$OldEnv=@{}
function WriteUtf8([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText($Path,$Text,$Utf8)}
function InvokeStep([string]$Name,[string]$Exe,[string[]]$Arguments,[int]$Seconds=600,[int]$Expected=0){
 $Log=Join-Path $Run ('logs\'+$Name);[IO.Directory]::CreateDirectory($Log)|Out-Null
 $Quoted=($Arguments|ForEach-Object{'"'+$_.Replace('"','\"')+'"'}) -join ' '
 $Start=[DateTime]::UtcNow
 $P=Start-Process -FilePath $Exe -ArgumentList $Quoted -WorkingDirectory $Workspace -RedirectStandardOutput (Join-Path $Log 'stdout.txt') -RedirectStandardError (Join-Path $Log 'stderr.txt') -PassThru -NoNewWindow
 if(-not $P.WaitForExit($Seconds*1000)){& "$env:SystemRoot\System32\taskkill.exe" /PID $P.Id /T /F 2>&1 |Out-File (Join-Path $Log 'termination.txt');throw ($Name+' exceeded '+$Seconds+' seconds; process-tree termination requested.')}
 $P.WaitForExit();$Code=$P.ExitCode
 $Steps.Add([ordered]@{name=$Name;exe=$Exe;arguments=$Arguments;started=$Start.ToString('o');ended=[DateTime]::UtcNow.ToString('o');exit_code=$Code;expected_exit=$Expected})
 WriteUtf8 (Join-Path $Run 'steps.json') (ConvertTo-Json -InputObject @($Steps.ToArray()) -Depth 8)
 if($Code -ne $Expected){throw ($Name+' exited '+$Code+'; expected '+$Expected+'. See its captured logs.')}
 Write-Host ('Finished: '+$Name)
}
function Checkpoint([string]$Name){
 $Dest=Join-Path $Run ('checkpoints\'+$Name);[IO.Directory]::CreateDirectory($Dest)|Out-Null
 Copy-Item -LiteralPath $Workspace -Destination (Join-Path $Dest 'source') -Recurse
 $Records=@(Get-ChildItem -LiteralPath $Dest -File -Recurse|ForEach-Object{[ordered]@{path=$_.FullName.Substring($Dest.Length+1);sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
 WriteUtf8 (Join-Path $Dest 'manifest.json') (ConvertTo-Json -InputObject $Records -Depth 6)
}
try{
 if($env:OS -ne 'Windows_NT'){throw 'Windows is required.'}
 if(-not [Environment]::Is64BitOperatingSystem){throw 'An x64 Windows installation is required.'}
 if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64'){throw 'This package is pinned to Windows AMD64, not ARM64.'}
 if(-not $Root){if(Test-Path 'E:\'){$Root='E:\dev\tools\c17-foundation-prototype'}else{$Root=Join-Path $env:LOCALAPPDATA 'C17FoundationPrototype'}}
 $Root=[IO.Path]::GetFullPath($Root);$Run=Join-Path $Root ('runs\'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
 [IO.Directory]::CreateDirectory($Run)|Out-Null
 $Workspace=Join-Path $Run 'workspace';[IO.Directory]::CreateDirectory($Workspace)|Out-Null
 Write-Host ('Run directory: '+$Run)
 $Identity=[Security.Principal.WindowsIdentity]::GetCurrent();$Principal=New-Object Security.Principal.WindowsPrincipal($Identity)
 if(-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run the one command in an elevated PowerShell window on the dedicated disposable VM. No elevation prompt is issued.'}
 if(Get-Process -Name cortexd,cortextray -ErrorAction SilentlyContinue){throw 'Live Cortex process detected. This package refuses to run here.'}
 if(-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)){throw 'Windows firewall command support is required.'}
 $Profiles=@(Get-NetFirewallProfile);if(@($Profiles|Where-Object{-not $_.Enabled}).Count -gt 0){throw 'Firewall profiles must already be enabled; this package does not silently enable host-wide policy.'}
 $SecretNames=@(Get-ChildItem Env:|Where-Object{$_.Name -match '(?i)(TOKEN|PASSWORD|SECRET|API_KEY|SERVICE_KEY|SUPABASE|AWS_|AZURE_|GOOGLE_APPLICATION_CREDENTIALS|GITHUB|GH_TOKEN)'}|ForEach-Object{$_.Name})
 if($SecretNames.Count -gt 0){throw ('Credential-like environment variables found; refusing to pass them to child tools. Names: '+($SecretNames -join ', '))}
 $Preflight=[ordered]@{version=$Version;windows=[Environment]::OSVersion.VersionString;principal=$Identity.Name;workspace=$Workspace;vm_isolation='operator-supplied dedicated disposable VM; hypervisor isolation not independently verified';production_process_check='no cortexd/cortextray observed';models='none';git_auth='not required';private_source='not accessed';scope='standalone synthetic foundation implementation, not integrated Cortex';utc=[DateTime]::UtcNow.ToString('o')}
 WriteUtf8 (Join-Path $Run 'preflight.json') (ConvertTo-Json $Preflight -Depth 6)
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $Metadata=Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json&include=all' -TimeoutSec 60
 $Release=@($Metadata|Where-Object{$_.version -eq $GoVersion});if($Release.Count -ne 1){throw ('Pinned Go release unavailable: '+$GoVersion)}
 $Archive=@($Release[0].files|Where-Object{$_.os -eq 'windows' -and $_.arch -eq 'amd64' -and $_.kind -eq 'archive'})
 if($Archive.Count -ne 1){throw 'Pinned Windows Go archive not uniquely resolved.'}
 $Package=$Archive[0];if($Package.sha256 -notmatch '^[0-9a-fA-F]{64}$'){throw 'Invalid official checksum metadata.'}
 $Zip=Join-Path $Run 'go-toolchain.zip'
 Invoke-WebRequest -UseBasicParsing -Uri ('https://go.dev/dl/'+$Package.filename) -OutFile $Zip -TimeoutSec 300
 if((Get-FileHash $Zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Package.sha256.ToLowerInvariant()){throw 'Go toolchain checksum mismatch; archive will not be executed.'}
 $Tools=Join-Path $Run 'toolchain';Expand-Archive -LiteralPath $Zip -DestinationPath $Tools
 $Go=Join-Path $Tools 'go\bin\go.exe'
 foreach($Name in @('GOROOT','GOPATH','GOCACHE','GOMODCACHE','GOTOOLCHAIN','GOPROXY','GOSUMDB','GOFLAGS','GOWORK','CGO_ENABLED')){$OldEnv[$Name]=[Environment]::GetEnvironmentVariable($Name,'Process')}
 $env:GOROOT=Join-Path $Tools 'go';$env:GOPATH=Join-Path $Run 'gopath';$env:GOCACHE=Join-Path $Run 'gocache';$env:GOMODCACHE=Join-Path $Run 'modules';$env:GOTOOLCHAIN='local';$env:GOPROXY='https://proxy.golang.org';$env:GOSUMDB='sum.golang.org';$env:GOFLAGS='';$env:GOWORK='off';$env:CGO_ENABLED='0'
 $Files=@{}
$Files['go.mod']=@'
module c17-prototype

go 1.25.0

require modernc.org/sqlite v1.56.0
'@
$Files['foundation/engine.go']=@'
package foundation

import (
 "crypto/sha256"
 "database/sql"
 "encoding/hex"
 "encoding/json"
 "errors"
 "fmt"
 "os"
 "path/filepath"
 "strings"
 "time"
 _ "modernc.org/sqlite"
)

type Engine struct { DB *sql.DB }
type Lease struct { Owner string; Token int64; Expires int64 }
type Observation struct { Operation string; Value string; Digest string }
func Hash(v string) string { s:=sha256.Sum256([]byte(v)); return hex.EncodeToString(s[:]) }
func Open(path string) (*Engine,error) {
 db,err:=sql.Open("sqlite",path); if err!=nil{return nil,err}; db.SetMaxOpenConns(1);db.SetMaxIdleConns(1)
 e:=&Engine{db}
 for _,q:=range []string{"PRAGMA busy_timeout=5000","PRAGMA foreign_keys=ON","PRAGMA journal_mode=WAL","PRAGMA synchronous=FULL",schema} {
  if _,err=db.Exec(q);err!=nil{db.Close();return nil,err}
 };return e,nil
}
const schema=`
CREATE TABLE IF NOT EXISTS gate(id INTEGER PRIMARY KEY CHECK(id=1), serial INTEGER NOT NULL, active TEXT, stopped INTEGER NOT NULL DEFAULT 0);
INSERT OR IGNORE INTO gate(id,serial) VALUES(1,0);
CREATE TABLE IF NOT EXISTS commands(id TEXT PRIMARY KEY,digest TEXT NOT NULL,result TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,entity TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS briefs(revision TEXT PRIMARY KEY,content TEXT NOT NULL,digest TEXT NOT NULL,blocking INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS reviews(id TEXT PRIMARY KEY,revision TEXT NOT NULL REFERENCES briefs(revision),actor TEXT NOT NULL,presented INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS approvals(id TEXT PRIMARY KEY,review TEXT NOT NULL UNIQUE REFERENCES reviews(id),revision TEXT NOT NULL,actor TEXT NOT NULL,turn TEXT NOT NULL,valid INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS lease(id INTEGER PRIMARY KEY CHECK(id=1),owner TEXT NOT NULL,token INTEGER NOT NULL,expires INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,attempt TEXT NOT NULL UNIQUE,submission TEXT NOT NULL UNIQUE,revision TEXT NOT NULL,approval TEXT NOT NULL,state TEXT NOT NULL,value TEXT);
CREATE TABLE IF NOT EXISTS observations(id TEXT PRIMARY KEY,operation TEXT NOT NULL REFERENCES operations(id),value TEXT NOT NULL,digest TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS checks(id TEXT PRIMARY KEY,operation TEXT NOT NULL REFERENCES operations(id),passed INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS publications(id TEXT PRIMARY KEY,operation TEXT NOT NULL REFERENCES operations(id),response_digest TEXT NOT NULL,delivered INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS completions(id TEXT PRIMARY KEY,operation TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS artifacts(id TEXT PRIMARY KEY,path TEXT NOT NULL,digest TEXT NOT NULL);
`
func (e *Engine) Close() error{return e.DB.Close()}
func (e *Engine) mutate(cmd,kind string,payload any,fn func(*sql.Tx)(string,error))(string,error){
 b,err:=json.Marshal(payload);if err!=nil{return "",err}; digest:=Hash(kind+":"+string(b))
 tx,err:=e.DB.Begin();if err!=nil{return "",err};defer tx.Rollback()
 if _,err=tx.Exec("UPDATE gate SET serial=serial+1 WHERE id=1");err!=nil{return "",err}
 var old,res string;err=tx.QueryRow("SELECT digest,result FROM commands WHERE id=?",cmd).Scan(&old,&res)
 if err==nil{if old!=digest{return "",errors.New("COMMAND_ID_CONFLICT")};return res,nil};if err!=sql.ErrNoRows{return "",err}
 res,err=fn(tx);if err!=nil{return "",err}
 if _,err=tx.Exec("INSERT INTO commands VALUES(?,?,?)",cmd,digest,res);err!=nil{return "",err}
 if _,err=tx.Exec("INSERT INTO events(kind,entity) VALUES(?,?)",kind,cmd);err!=nil{return "",err}
 if err=tx.Commit();err!=nil{return "",err};return res,nil
}
func (e *Engine) Brief(cmd,rev,content string,blocking bool) error {
 _,err:=e.mutate(cmd,"brief",[]any{rev,content,blocking},func(tx *sql.Tx)(string,error){
  _,err:=tx.Exec("INSERT INTO briefs VALUES(?,?,?,?)",rev,content,Hash(content),blocking);return rev,err
 });return err
}
func (e *Engine) Present(cmd,review,rev,actor string)error{
 _,err:=e.mutate(cmd,"present",[]string{review,rev,actor},func(tx *sql.Tx)(string,error){
  _,err:=tx.Exec("INSERT INTO reviews VALUES(?,?,?,1)",review,rev,actor);return review,err
 });return err
}
func (e *Engine) Approve(cmd,approval,review,actor,turn,reply string)error{
 _,err:=e.mutate(cmd,"approve",[]string{approval,review,actor,turn,reply},func(tx *sql.Tx)(string,error){
  if turn==""||strings.ToLower(strings.TrimSpace(reply))!="yes"{return "",errors.New("NOT_EXACT_APPROVAL")}
  var rev,want string;var presented int
  if err:=tx.QueryRow("SELECT revision,actor,presented FROM reviews WHERE id=?",review).Scan(&rev,&want,&presented);err!=nil{return "",err}
  if want!=actor||presented!=1{return "",errors.New("APPROVAL_NOT_AUTHORIZED_OR_PRESENTED")}
  _,err:=tx.Exec("INSERT INTO approvals VALUES(?,?,?,?,?,1)",approval,review,rev,actor,turn);return approval,err
 });return err
}
func(e *Engine) ApproveLatest(cmd,approval,actor,turn,reply string)error{
 rows,err:=e.DB.Query("SELECT r.id FROM reviews r LEFT JOIN approvals a ON a.review=r.id WHERE r.actor=? AND a.id IS NULL",actor);if err!=nil{return err}
 var ids []string;for rows.Next(){var id string;if err=rows.Scan(&id);err!=nil{rows.Close();return err};ids=append(ids,id)};err=rows.Err();rows.Close();if err!=nil{return err}
 if len(ids)!=1{return errors.New("APPROVAL_AMBIGUOUS")};return e.Approve(cmd,approval,ids[0],actor,turn,reply)
}
func(e *Engine) Activate(cmd,rev,approval string)error{
 _,err:=e.mutate(cmd,"activate",[]string{rev,approval},func(tx *sql.Tx)(string,error){
  var got string;var valid,blocking int
  if err:=tx.QueryRow("SELECT a.revision,a.valid,b.blocking FROM approvals a JOIN briefs b ON b.revision=a.revision WHERE a.id=?",approval).Scan(&got,&valid,&blocking);err!=nil{return "",err}
  if got!=rev||valid!=1||blocking!=0{return "",errors.New("INELIGIBLE")}
  _,err:=tx.Exec("UPDATE gate SET active=? WHERE id=1",rev);return rev,err
 });return err
}
func(e *Engine) Withdraw(cmd,approval string)error{
 _,err:=e.mutate(cmd,"withdraw",approval,func(tx *sql.Tx)(string,error){r,err:=tx.Exec("UPDATE approvals SET valid=0 WHERE id=?",approval);if err!=nil{return "",err};n,_:=r.RowsAffected();if n!=1{return "",errors.New("MISSING_APPROVAL")};return approval,nil});return err
}
func(e *Engine) Stop(cmd string)error{
 _,err:=e.mutate(cmd,"stop",true,func(tx *sql.Tx)(string,error){_,err:=tx.Exec("UPDATE gate SET stopped=1 WHERE id=1");return "stopped",err});return err
}
func(e *Engine) Claim(cmd,owner string,now,ttl int64)(Lease,error){
 var l Lease;res,err:=e.mutate(cmd,"lease",[]any{owner,now,ttl},func(tx *sql.Tx)(string,error){
  if owner==""||ttl<=0{return "",errors.New("INVALID_LEASE")}
  var old Lease;err:=tx.QueryRow("SELECT owner,token,expires FROM lease WHERE id=1").Scan(&old.Owner,&old.Token,&old.Expires)
  if err!=nil&&err!=sql.ErrNoRows{return "",err};if err==nil&&old.Expires>now{return "",errors.New("LEASE_BUSY")}
  l=Lease{owner,old.Token+1,now+ttl};_,err=tx.Exec("INSERT INTO lease VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET owner=excluded.owner,token=excluded.token,expires=excluded.expires",l.Owner,l.Token,l.Expires)
  b,_:=json.Marshal(l);return string(b),err
 });if err==nil{err=json.Unmarshal([]byte(res),&l)};return l,err
}
func(e *Engine) Accept(cmd,op,attempt,submission,rev,approval,kind string,l Lease,now int64,recovery bool)error{
 payload:=[]any{op,attempt,submission,rev,approval,kind,l,now,recovery}
 _,err:=e.mutate(cmd,"accept",payload,func(tx *sql.Tx)(string,error){
  if recovery{return "",errors.New("RECOVERY_ONLY")};if kind!="mock_read"{return "",errors.New("READ_ONLY_PROFILE")}
  var active sql.NullString;var stopped int;if err:=tx.QueryRow("SELECT active,stopped FROM gate WHERE id=1").Scan(&active,&stopped);err!=nil{return "",err}
  if stopped!=0||!active.Valid||active.String!=rev{return "",errors.New("STOPPED_OR_REVISION_INACTIVE")}
  var aRev string;var valid,blocking int
  if err:=tx.QueryRow("SELECT a.revision,a.valid,b.blocking FROM approvals a JOIN briefs b ON b.revision=a.revision WHERE a.id=?",approval).Scan(&aRev,&valid,&blocking);err!=nil{return "",err}
  if aRev!=rev||valid!=1||blocking!=0{return "",errors.New("APPROVAL_INVALID")}
  var current Lease;if err:=tx.QueryRow("SELECT owner,token,expires FROM lease WHERE id=1").Scan(&current.Owner,&current.Token,&current.Expires);err!=nil{return "",err}
  if current.Owner!=l.Owner||current.Token!=l.Token||current.Expires<=now{return "",errors.New("STALE_WORKER")}
  var oldAttempt,oldSub,oldRev,oldApproval string
  err:=tx.QueryRow("SELECT attempt,submission,revision,approval FROM operations WHERE id=?",op).Scan(&oldAttempt,&oldSub,&oldRev,&oldApproval)
  if err==nil{if oldAttempt!=attempt||oldSub!=submission||oldRev!=rev||oldApproval!=approval{return "",errors.New("OPERATION_ID_CONFLICT")};return op,nil}
  if err!=sql.ErrNoRows{return "",err}
  _,err=tx.Exec("INSERT INTO operations(id,attempt,submission,revision,approval,state) VALUES(?,?,?,?,?,'accepted')",op,attempt,submission,rev,approval);return op,err
 });return err
}
func(e *Engine) Unknown(cmd,op string)error{
 _,err:=e.mutate(cmd,"unknown",op,func(tx *sql.Tx)(string,error){r,err:=tx.Exec("UPDATE operations SET state='outcome_unknown' WHERE id=? AND state='accepted'",op);if err!=nil{return "",err};n,_:=r.RowsAffected();if n!=1{return "",errors.New("INVALID_TRANSITION")};return op,nil});return err
}
func(e *Engine) Observe(cmd,id,op,value string)error{
 _,err:=e.mutate(cmd,"observe",[]string{id,op,value},func(tx *sql.Tx)(string,error){
  var state string;if err:=tx.QueryRow("SELECT state FROM operations WHERE id=?",op).Scan(&state);err!=nil{return "",err}
  if state!="accepted"&&state!="outcome_unknown"{return "",errors.New("INVALID_TRANSITION")}
  if _,err:=tx.Exec("INSERT INTO observations VALUES(?,?,?,?)",id,op,value,Hash(value));err!=nil{return "",err}
  _,err:=tx.Exec("UPDATE operations SET state='succeeded',value=? WHERE id=?",value,op);return id,err
 });return err
}
func(e *Engine) Check(cmd,id,op,expected string)error{
 _,err:=e.mutate(cmd,"check",[]string{id,op,expected},func(tx *sql.Tx)(string,error){
  var value,digest string;if err:=tx.QueryRow("SELECT value,digest FROM observations WHERE operation=?",op).Scan(&value,&digest);err!=nil{return "",err}
  passed:=value==expected&&digest==Hash(value);_,err:=tx.Exec("INSERT INTO checks VALUES(?,?,?)",id,op,passed);return fmt.Sprint(passed),err
 });return err
}
func(e *Engine) Verify(cmd,id,op,response string)error{
 _,err:=e.mutate(cmd,"verify",[]string{id,op,response},func(tx *sql.Tx)(string,error){
  var value string;if err:=tx.QueryRow("SELECT value FROM observations WHERE operation=?",op).Scan(&value);err!=nil{return "",err}
  if response!="Observed value: "+value{return "",errors.New("UNSUPPORTED_RESPONSE")}
  var n int;if err:=tx.QueryRow("SELECT count(*) FROM checks WHERE operation=? AND passed=1",op).Scan(&n);err!=nil{return "",err};if n<1{return "",errors.New("VERIFICATION_REQUIRED")}
  _,err:=tx.Exec("INSERT INTO publications VALUES(?,?,?,0)",id,op,Hash(response));return id,err
 });return err
}
func(e *Engine) Deliver(cmd,id,response string,confirmed bool)error{
 _,err:=e.mutate(cmd,"deliver",[]any{id,response,confirmed},func(tx *sql.Tx)(string,error){
  var digest string;if err:=tx.QueryRow("SELECT response_digest FROM publications WHERE id=?",id).Scan(&digest);err!=nil{return "",err};if digest!=Hash(response){return "",errors.New("DIGEST_MISMATCH")}
  if !confirmed{return "delivery_unknown",nil};_,err:=tx.Exec("UPDATE publications SET delivered=1 WHERE id=?",id);return "delivered",err
 });return err
}
func(e *Engine) Complete(cmd,task,op string)error{
 _,err:=e.mutate(cmd,"complete",[]string{task,op},func(tx *sql.Tx)(string,error){
  var n int;if err:=tx.QueryRow("SELECT count(*) FROM publications WHERE operation=? AND delivered=1",op).Scan(&n);err!=nil{return "",err};if n<1{return "",errors.New("DELIVERY_REQUIRED")}
  if err:=tx.QueryRow("SELECT count(*) FROM checks WHERE operation=? AND passed=0",op).Scan(&n);err!=nil{return "",err};if n>0{return "",errors.New("FAILED_CHECK")}
  _,err:=tx.Exec("INSERT INTO completions VALUES(?,?)",task,op);return task,err
 });return err
}
func(e *Engine) Count(table string)(int,error){
 allowed:=map[string]bool{"approvals":true,"operations":true,"events":true,"completions":true,"observations":true,"artifacts":true};if !allowed[table]{return 0,errors.New("INVALID_TABLE")}
 var n int;err:=e.DB.QueryRow("SELECT count(*) FROM "+table).Scan(&n);return n,err
}
func(e *Engine) Artifact(cmd,id,dir,content string)error{
 if err:=os.MkdirAll(dir,0700);err!=nil{return err};digest:=Hash(content);dest:=filepath.Join(dir,digest+".txt")
 temp,err:=os.CreateTemp(dir,"pending-");if err!=nil{return err};name:=temp.Name();defer os.Remove(name)
 if _,err=temp.WriteString(content);err!=nil{temp.Close();return err};if err=temp.Sync();err!=nil{temp.Close();return err};if err=temp.Close();err!=nil{return err}
 if old,err:=os.ReadFile(dest);err==nil{if Hash(string(old))!=digest{return errors.New("ARTIFACT_TAMPERED")}}else if !os.IsNotExist(err){return err}else if err=os.Rename(name,dest);err!=nil{return err}
 _,err=e.mutate(cmd,"artifact",[]string{id,digest},func(tx *sql.Tx)(string,error){_,err:=tx.Exec("INSERT INTO artifacts VALUES(?,?,?)",id,dest,digest);return id,err});return err
}
func(e *Engine) VerifyArtifact(id string)error{var path,digest string;if err:=e.DB.QueryRow("SELECT path,digest FROM artifacts WHERE id=?",id).Scan(&path,&digest);err!=nil{return err};b,err:=os.ReadFile(path);if err!=nil{return err};if Hash(string(b))!=digest{return errors.New("ARTIFACT_TAMPERED")};return nil}
func Now()int64{return time.Now().Unix()}
'@
$Files['foundation/engine_test.go']=@'
package foundation
import("database/sql";"fmt";"os";"path/filepath";"sync";"testing")
func fixture(t *testing.T)(*Engine,Lease,string){t.Helper();path:=filepath.Join(t.TempDir(),"state.db");e,err:=Open(path);if err!=nil{t.Fatal(err)};t.Cleanup(func(){e.Close()});must(t,e.Brief("b","R1","read fixture",false));must(t,e.Present("p","V1","R1","test-user"));must(t,e.Approve("a","A1","V1","test-user","T1","yes"));must(t,e.Activate("act","R1","A1"));l,err:=e.Claim("lease","worker",10,100);must(t,err);return e,l,path}
func must(t *testing.T,err error){t.Helper();if err!=nil{t.Fatal(err)}}
func reject(t *testing.T,err error){t.Helper();if err==nil{t.Fatal("expected rejection")}}
func accept(e *Engine,l Lease,cmd,op string)error{return e.Accept(cmd,op,"attempt-"+op,"submission-"+op,"R1","A1","mock_read",l,11,false)}
func observed(t *testing.T,e *Engine,l Lease){must(t,accept(e,l,"send","O1"));must(t,e.Observe("obs","E1","O1","17"))}
func TestExactApproval(t *testing.T){e,_,_:=fixture(t);var rev,actor,turn string;must(t,e.DB.QueryRow("SELECT revision,actor,turn FROM approvals WHERE id='A1'").Scan(&rev,&actor,&turn));if rev!="R1"||actor!="test-user"||turn!="T1"{t.Fatal("approval binding wrong")}}
func TestImmutableRevision(t *testing.T){e,_,_:=fixture(t);reject(t,e.Brief("new","R1","changed",false))}
func TestConditionalAndWrongActor(t *testing.T){e,_,_:=fixture(t);must(t,e.Present("p2","V2","R1","test-user"));reject(t,e.Approve("x","A2","V2","test-user","T2","yes but deploy"));reject(t,e.Approve("y","A3","V2","model","T3","yes"))}
func TestAmbiguousApproval(t *testing.T){e,_,_:=fixture(t);must(t,e.Present("p2","V2","R1","test-user"));must(t,e.Present("p3","V3","R1","test-user"));reject(t,e.ApproveLatest("x","A2","test-user","T2","yes"));n,_:=e.Count("approvals");if n!=1{t.Fatal(n)}}
func TestMissingPresentation(t *testing.T){e,_,_:=fixture(t);reject(t,e.Approve("x","A2","absent","test-user","T2","yes"))}
func TestChangedRevision(t *testing.T){e,_,_:=fixture(t);must(t,e.Brief("b2","R2","new scope",false));reject(t,e.Activate("act2","R2","A1"))}
func TestBlockingQuestion(t *testing.T){e,_,_:=fixture(t);must(t,e.Brief("b2","R2","unknown target",true));must(t,e.Present("p2","V2","R2","test-user"));must(t,e.Approve("a2","A2","V2","test-user","T2","yes"));reject(t,e.Activate("act2","R2","A2"))}
func TestDuplicateAndConflictingCommand(t *testing.T){e,l,_:=fixture(t);must(t,accept(e,l,"send","O1"));must(t,accept(e,l,"send","O1"));reject(t,accept(e,l,"send","O2"));n,_:=e.Count("operations");if n!=1{t.Fatal(n)}}
func TestDuplicateOperation(t *testing.T){e,l,_:=fixture(t);must(t,accept(e,l,"send1","O1"));must(t,accept(e,l,"send2","O1"));n,_:=e.Count("operations");if n!=1{t.Fatal(n)}}
func TestWithdrawalBeforeAcceptance(t *testing.T){e,l,_:=fixture(t);must(t,e.Withdraw("w","A1"));reject(t,accept(e,l,"send","O1"))}
func TestConcurrentWithdrawalAndAcceptance(t *testing.T){e,l,path:=fixture(t);other,err:=Open(path);must(t,err);defer other.Close();start:=make(chan struct{});var wg sync.WaitGroup;var a,w error;wg.Add(2);go func(){defer wg.Done();<-start;a=accept(e,l,"send","O1")}();go func(){defer wg.Done();<-start;w=other.Withdraw("w","A1")}();close(start);wg.Wait();must(t,w);n,_:=e.Count("operations");if (a==nil&&n!=1)||(a!=nil&&n!=0){t.Fatal("inconsistent ordering")};reject(t,accept(e,l,"after","O2"))}
func TestStaleWorker(t *testing.T){e,l,_:=fixture(t);newLease,err:=e.Claim("lease2","replacement",111,100);must(t,err);if newLease.Token<=l.Token{t.Fatal("not fenced")};reject(t,e.Accept("send","O1","AT1","S1","R1","A1","mock_read",l,112,false))}
func TestStopAndProfiles(t *testing.T){e,l,_:=fixture(t);for _,kind:=range []string{"write","aeox","memory_promote","restart","deploy"}{reject(t,e.Accept(kind,kind,"at-"+kind,"s-"+kind,"R1","A1",kind,l,11,false))};must(t,e.Stop("stop"));reject(t,accept(e,l,"send","O1"))}
func TestRecoveryOnly(t *testing.T){e,l,_:=fixture(t);reject(t,e.Accept("send","O1","AT1","S1","R1","A1","mock_read",l,11,true))}
func TestUnknownPersistsAfterReopen(t *testing.T){e,l,path:=fixture(t);must(t,accept(e,l,"send","O1"));must(t,e.Unknown("u","O1"));must(t,e.Close());reopened,err:=Open(path);must(t,err);defer reopened.Close();var state,sub string;must(t,reopened.DB.QueryRow("SELECT state,submission FROM operations WHERE id='O1'").Scan(&state,&sub));if state!="outcome_unknown"||sub!="submission-O1"{t.Fatal(state,sub)}}
func TestUnsupportedCancellationRetainsUnknown(t *testing.T){e,l,_:=fixture(t);must(t,accept(e,l,"send","O1"));must(t,e.Unknown("cancel-unknown","O1"));var state string;must(t,e.DB.QueryRow("SELECT state FROM operations WHERE id='O1'").Scan(&state));if state!="outcome_unknown"{t.Fatal(state)}}
func TestEvidenceAndEditedResponse(t *testing.T){e,l,_:=fixture(t);observed(t,e,l);must(t,e.Check("check","C1","O1","17"));reject(t,e.Verify("bad","P0","O1","Observed value: 42"));must(t,e.Verify("v","P1","O1","Observed value: 17"));reject(t,e.Deliver("edited","P1","Observed value: 42",true))}
func TestMissingCheckBlocksPublication(t *testing.T){e,l,_:=fixture(t);observed(t,e,l);reject(t,e.Verify("v","P1","O1","Observed value: 17"));reject(t,e.Complete("done","TASK","O1"))}
func TestUnknownDeliveryBlocksCompletion(t *testing.T){e,l,_:=fixture(t);observed(t,e,l);must(t,e.Check("c","C1","O1","17"));must(t,e.Verify("v","P1","O1","Observed value: 17"));must(t,e.Deliver("d","P1","Observed value: 17",false));reject(t,e.Complete("done","TASK","O1"))}
func TestCompletedRequiresPassedChecksAndDelivery(t *testing.T){e,l,_:=fixture(t);observed(t,e,l);must(t,e.Check("c","C1","O1","17"));must(t,e.Verify("v","P1","O1","Observed value: 17"));must(t,e.Deliver("d","P1","Observed value: 17",true));must(t,e.Complete("done","TASK","O1"));n,_:=e.Count("completions");if n!=1{t.Fatal(n)}}
func TestFailedCheckBlocksCompletion(t *testing.T){e,l,_:=fixture(t);observed(t,e,l);must(t,e.Check("c","C1","O1","42"));reject(t,e.Verify("v","P1","O1","Observed value: 17"))}
func TestRollbackIncludesAudit(t *testing.T){e,_,_:=fixture(t);before,_:=e.Count("events");_,err:=e.mutate("broken","broken",nil,func(tx *sql.Tx)(string,error){_,err:=tx.Exec("INSERT INTO artifacts VALUES('partial','x','x')");if err!=nil{return "",err};return "",fmt.Errorf("injected failure")});reject(t,err);after,_:=e.Count("events");n,_:=e.Count("artifacts");if after!=before||n!=0{t.Fatal("partial state")}}
func TestArtifactTamperAndMissing(t *testing.T){e,_,_:=fixture(t);dir:=t.TempDir();must(t,e.Artifact("art","F1",dir,"fixture"));must(t,e.VerifyArtifact("F1"));path:=filepath.Join(dir,Hash("fixture")+".txt");must(t,os.WriteFile(path,[]byte("tampered"),0600));reject(t,e.VerifyArtifact("F1"));must(t,os.Remove(path));reject(t,e.VerifyArtifact("F1"))}
func TestRequiredStoreFailure(t *testing.T){path:=t.TempDir();e,err:=Open(path);if e!=nil{e.Close()};reject(t,err)}
'@
$Files['cmd/prototype/main.go']=@'
package main
import("database/sql";"encoding/json";"fmt";"os";"path/filepath"; f "c17-prototype/foundation")
func must(err error){if err!=nil{fmt.Fprintln(os.Stderr,err);os.Exit(1)}}
func main(){if len(os.Args)!=3{fmt.Fprintln(os.Stderr,"usage: prototype seed|crash|recover DIRECTORY");os.Exit(2)};mode,dir:=os.Args[1],os.Args[2];must(os.MkdirAll(dir,0700));e,err:=f.Open(filepath.Join(dir,"state.db"));must(err);defer e.Close();mock,err:=sql.Open("sqlite",filepath.Join(dir,"mock-external.db"));must(err);defer mock.Close();_,err=mock.Exec("CREATE TABLE IF NOT EXISTS submissions(id TEXT PRIMARY KEY,value TEXT NOT NULL,submit_count INTEGER NOT NULL)");must(err)
 switch mode{
 case "seed":
  must(e.Brief("b","R1","read synthetic 17",false));must(e.Present("p","V1","R1","synthetic-user"));must(e.Approve("a","A1","V1","synthetic-user","T1","yes"));must(e.Activate("act","R1","A1"));_,err=e.Claim("l","worker",10,100);must(err);fmt.Println("SEEDED")
 case "crash":
  l:=f.Lease{Owner:"worker",Token:1,Expires:110};must(e.Accept("accept","O1","AT1","S1","R1","A1","mock_read",l,11,false));must(e.Unknown("unknown","O1"));_,err=mock.Exec("INSERT INTO submissions VALUES('S1','17',1)");must(err);fmt.Fprintln(os.Stdout,"FAULT_INJECTED_AFTER_EXTERNAL_ACCEPTANCE");os.Exit(23)
 case "recover":
  var sub,state,value string;must(e.DB.QueryRow("SELECT submission,state FROM operations WHERE id='O1'").Scan(&sub,&state));if state!="outcome_unknown"{must(fmt.Errorf("unexpected state %s",state))};must(mock.QueryRow("SELECT value FROM submissions WHERE id=?",sub).Scan(&value));must(e.Observe("obs","E1","O1",value));must(e.Check("check","C1","O1","17"));response:="Observed value: "+value;must(e.Verify("verify","P1","O1",response));must(e.Deliver("delivery","P1",response,true));must(e.Complete("done","TASK1","O1"));must(e.Artifact("art","F1",filepath.Join(dir,"artifacts"),response));must(e.VerifyArtifact("F1"));var count int;must(mock.QueryRow("SELECT sum(submit_count) FROM submissions").Scan(&count));if count!=1{must(fmt.Errorf("duplicate external submission: %d",count))};result:=map[string]any{"status":"PASSED_SYNTHETIC_DEMO","external_submissions":count,"response":response,"reconciled_submission":sub,"production_touched":false};b,err:=json.MarshalIndent(result,"","  ");must(err);must(os.WriteFile(filepath.Join(dir,"demo-result.json"),b,0600));fmt.Println(string(b))
 default:must(fmt.Errorf("unknown mode"))
 }
}
'@
 foreach($Name in $Files.Keys){WriteUtf8 (Join-Path $Workspace $Name) $Files[$Name]}
 $SourceHashes=@(Get-ChildItem $Workspace -File -Recurse|ForEach-Object{[ordered]@{path=$_.FullName.Substring($Workspace.Length+1);sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
 WriteUtf8 (Join-Path $Run 'source-manifest.json') (ConvertTo-Json -InputObject $SourceHashes -Depth 5)
 WriteUtf8 (Join-Path $Run 'toolchain.json') (ConvertTo-Json ([ordered]@{version=$GoVersion;filename=$Package.filename;sha256=$Package.sha256;source='official go.dev metadata'}) -Depth 5)
 InvokeStep 'toolchain-version' $Go @('version') 30
 InvokeStep 'dependency-resolution' $Go @('mod','tidy') 600
 InvokeStep 'dependency-integrity' $Go @('mod','verify') 120
 InvokeStep 'dependency-lock' $Go @('list','-m','-json','all') 60
 InvokeStep 'vendor' $Go @('mod','vendor') 120
 $env:GOPROXY='off';$env:GOFLAGS='-mod=vendor'
 InvokeStep 'format' $Go @('fmt','./...') 60
 Checkpoint 'source-and-dependencies'
 InvokeStep 'static-analysis' $Go @('vet','./...') 300
 $TestExe=Join-Path $Run 'prototype-tests.exe';$DemoExe=Join-Path $Run 'prototype.exe'
 InvokeStep 'compile-tests' $Go @('test','-c','-o',$TestExe,'./foundation') 600
 InvokeStep 'build-demo' $Go @('build','-trimpath','-o',$DemoExe,'./cmd/prototype') 600
 foreach($Exe in @($TestExe,$DemoExe,$Go)){
  $Rule='C17Prototype-'+[Guid]::NewGuid().ToString('N');$Rules.Add($Rule)
  New-NetFirewallRule -Name $Rule -DisplayName $Rule -Direction Outbound -Action Block -Program $Exe -Profile Any -Enabled True|Out-Null
  $Installed=Get-NetFirewallRule -Name $Rule;if($Installed.Action -ne 'Block' -or $Installed.Enabled -ne 'True'){throw 'Program-scoped network restriction could not be confirmed.'}
 }
 for($I=1;$I -le 3;$I++){InvokeStep ('acceptance-'+$I) $TestExe @('-test.v','-test.timeout=120s') 150}
 $Log=Get-Content (Join-Path $Run 'logs\acceptance-1\stdout.txt') -Raw
 $TestCount=([regex]::Matches($Log,'(?m)^--- PASS: Test')).Count
 if($TestCount -lt 24){throw ('Acceptance execution count unexpected: '+$TestCount)}
 $DemoDir=Join-Path $Run 'demo'
 InvokeStep 'demo-seed' $DemoExe @('seed',$DemoDir) 30
 InvokeStep 'demo-intentional-crash' $DemoExe @('crash',$DemoDir) 30 23
 InvokeStep 'demo-recovery' $DemoExe @('recover',$DemoDir) 30
 $Result=Get-Content (Join-Path $DemoDir 'demo-result.json') -Raw|ConvertFrom-Json
 if($Result.status -ne 'PASSED_SYNTHETIC_DEMO' -or $Result.external_submissions -ne 1){throw 'Recovery result failed required assertions.'}
 Checkpoint 'passed-foundation'
 $Status='PASSED_BOUNDED_PROTOTYPE'
}catch{$Failure=$_.Exception.Message;if($Steps.Count -gt 0){$Status='FAILED_OR_BLOCKED'};Write-Host ('Stopped honestly: '+$Failure)}
finally{
 $CleanupErrors=New-Object System.Collections.Generic.List[string]
 foreach($Rule in $Rules){try{Remove-NetFirewallRule -Name $Rule -ErrorAction Stop}catch{$CleanupErrors.Add('Firewall rule cleanup failed: '+$Rule)}}
 foreach($Name in $OldEnv.Keys){[Environment]::SetEnvironmentVariable($Name,$OldEnv[$Name],'Process')}
 if($CleanupErrors.Count -gt 0){$Status='BLOCKED_CLEANUP';$Failure=$Failure+' '+($CleanupErrors -join '; ')}
 if($Run){
  $Report=[ordered]@{status=$Status;package_version=$Version;finished_utc=[DateTime]::UtcNow.ToString('o');failure=$Failure;test_functions=$TestCount;test_repetitions=3;steps=@($Steps.ToArray());scope='standalone Go/SQLite synthetic prototype';not_proven=@('Cortex repository integration','tools/verify.py documentation checker','Windows execution validated before delivery','power-loss durability','complete original prototype-brief acceptance coverage','autonomous code repair','arbitrary natural-language truth checking','AEOX or live Supabase correctness','hypervisor isolation');no_production_access=$true;no_models=$true;automatic_code_repair='not implemented: supplied deterministic source builds/tests; failure emits report rather than changing requirements';checkpoint_limit='local same-drive copies, not off-device backups';cleanup_errors=@($CleanupErrors.ToArray())}
  WriteUtf8 (Join-Path $Run 'report.json') (ConvertTo-Json $Report -Depth 12)
  $Lines=@('C17 FOUNDATION PROTOTYPE FINAL REPORT','STATUS: '+$Status,'PACKAGE: '+$Version,'RUN: '+$Run,'FAILURE: '+$Failure,'ACCEPTANCE TEST FUNCTIONS: '+$TestCount,'Scope: standalone synthetic Go/SQLite foundation; no live Cortex integration.','No private GitHub authentication, model calls, production data access, deployment or Git push.','Automatic code repair is not implemented. Any failure is recorded, not hidden.','Documentation checker and live-system acceptance were NOT RUN.','VM isolation is operator-supplied; not independently established by this launcher.','Checkpoints are local same-drive copies, not off-device backup.','', 'COMMAND RESULTS:')
  foreach($Step in $Steps){$Lines+=($Step.name+': exit '+$Step.exit_code+' (expected '+$Step.expected_exit+')')}
  $Lines+=@('','LIMITATIONS:');$Lines+=$Report.not_proven
  WriteUtf8 (Join-Path $Run 'FINAL-REPORT.txt') ($Lines -join [Environment]::NewLine)
  Write-Host '';Write-Host ('FINAL STATUS: '+$Status);Write-Host ('FINAL REPORT: '+(Join-Path $Run 'FINAL-REPORT.txt'));Write-Host 'Return that single report; supporting logs and source are retained beside it.'
 }else{Write-Host ('BOOTSTRAP BLOCKED BEFORE REPORT DIRECTORY: '+$Failure)}
}
if($Status -ne 'PASSED_BOUNDED_PROTOTYPE'){exit 1}
