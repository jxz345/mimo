#!/usr/bin/env python3
"""Isolated actual guard dispatch, supervisor cadence and health projection.
Only root/OS operations and clock/sleep are substituted. No real system paths,
launchd jobs, PF commands, processes or VM are inspected or changed.
"""
from pathlib import Path
import sys,json,hashlib,subprocess,os
ROOT=Path(__file__).resolve().parents[3]; HERE=Path(__file__).resolve().parent
out=Path(sys.argv[1]).resolve();assert out.is_relative_to(ROOT/'.build') and not out.exists();out.mkdir(parents=True);gen=out/'generated';gen.mkdir()
def member(source,name):
 a=source.index(name);b=source.index('{',a);end=b+1;depth=1
 while depth:depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[a:end]
sup=(ROOT/'Sources/MimoService/MimoSupervisor.swift').read_text()
a=sup.index('        infrastructureMonitor = Task {');b=sup.index('        watchdog = Task {',a)
loop=sup[a:b].replace('try? await Task.sleep(for: .seconds(10))','await self.testSleep(seconds: 10)')
runtime=(ROOT/'Sources/MimoService/MimoSystemRuntime.swift').read_text()
repair=member(runtime,'    func repairInfrastructure(').replace('checkedAt: .now','checkedAt: TestClock.shared.date').replace('startedAt: .now','startedAt: TestClock.shared.date').replace('completedAt = .now','completedAt = TestClock.shared.date')
status=member(runtime,'    func infrastructureStatus(').replace('.current(at: .now)', '.current(at: TestClock.shared.date)')
scope=member(runtime,'    private func pfHealthReceiptIsCurrent(').replace('at: .now','at: TestClock.shared.date')
model=(ROOT/'Sources/MimoShared/MimoRouting.swift').read_text()
models='\n'.join(member(model,n) for n in ['public enum MimoHealthLabel','public enum MimoInfrastructureHealth:','public enum MimoInfrastructureCheckOutcome:','public struct MimoInfrastructureInspection:','public struct MimoInfrastructureStatus:'])
failure=member(sup,'    private func infrastructureInspectionFailed(').replace('private func','func')
request=member(sup,'    private func requestInfrastructureReconciliation(').replace('private func','func')
(gen/'Slices.swift').write_text('import Foundation\n'+models+'\n@MainActor final class MimoSystemRuntime {\n'+(HERE/'runtime-stubs.swift').read_text()+repair+'\n'+status+'\n'+scope+'\n}\n@MainActor final class SupervisorHarness {\n'+(HERE/'supervisor-stubs.swift').read_text()+failure+'\n'+request+'\nfunc start() {\n'+loop+'\n}\n}\n')
guard=(ROOT/'Sources/MimoDaemon/pf-guard.pl').read_text()
# Only fixed paths, administrator precondition and OS-side functions are changed.
guard=guard.replace("my $support = '/Library/Application Support/Mimo';",'my $support = $ENV{HEALTH_TEST_ROOT};')
guard=guard.replace("my $guard = '/Library/Application Support/Mimo/Guard';",'my $guard = "$support/Guard";')
guard=guard.replace("my $rules = '/etc/pf.anchors/com.mimo.boot';",'my $rules = "$support/boot.pf";')
guard=guard.replace("my $configuration = '/etc/pf.conf';",'my $configuration = "$support/pf.conf";')
guard=guard.replace('unless $> == 0','unless $ENV{HEALTH_TEST_ROOT}')
a=guard.index('unless (caller) {')
guard=guard[:a]+(HERE/'guard-stubs.pl').read_text()+'\n'+guard[a:]
(gen/'guard.pl').write_text(guard)
sources=['Sources/MimoService/MimoSupervisor.swift','Sources/MimoService/MimoSystemRuntime.swift','Sources/MimoShared/MimoRouting.swift','Sources/MimoDaemon/pf-guard.pl','Sources/MimoService/MimoInfrastructureScheduler.swift','Sources/MimoService/MimoPFHealthReceipt.swift','Sources/MimoService/MimoProtectedIO.swift','Sources/MimoService/MimoDirectRelease.swift','Sources/MimoService/DaemonMain.swift']
(out/'sources.json').write_text(json.dumps({x:hashlib.sha256((ROOT/x).read_bytes()).hexdigest() for x in sources},indent=2)+'\n')
for source in sources:
 path=out/'original'/source;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes((ROOT/source).read_bytes())
files=[gen/'Slices.swift',HERE/'support.swift',HERE/'cases.swift',ROOT/'Sources/MimoService/MimoBlockingWorkQueue.swift',ROOT/'Sources/MimoService/MimoInfrastructureScheduler.swift',ROOT/'Sources/MimoService/MimoPFHealthReceipt.swift']
r=subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',*map(str,files),'-o',str(out/'test')],capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode:print(r.stderr[-9000:]);sys.exit(r.returncode)
r=subprocess.run([str(out/'test'),str(out),str(gen/'guard.pl'),*sys.argv[2:]],capture_output=True,text=True,timeout=40);(out/'test.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);sys.exit(r.returncode)
