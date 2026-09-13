import XCTest
import JavaScriptCore
@testable import QuotaShared

final class ElectronDockTests: XCTestCase {
    func testRuntimeUpdatesSurviveAppOverwriteAndRestoreLatestAppIcon() throws {
        let context = JSContext()!
        var scriptError: String?
        context.exceptionHandler = { _, error in scriptError = error?.toString() }
        context.evaluateScript("""
        var currentIcon=null, scheduled=[], listeners={}, closeCount=0;
        var originalSetIcon=function(image){currentIcon=image;};
        var app={dock:{setIcon:originalSetIcon}};
        var nativeImage={createFromPath:function(path){return {path:path,isEmpty:function(){return path==='missing';}};}};
        var nativeTheme={shouldUseDarkColorsForSystemIntegratedUI:false,
          on:function(event,fn){listeners[event]=fn;},removeListener:function(event,fn){if(listeners[event]===fn)delete listeners[event];}};
        var process={pid:123,execPath:'/test/App',getBuiltinModule:function(name){
          if(name==='inspector')return {close:function(){closeCount++;}};
          if(name==='module')return {createRequire:function(){return function(){return {app:app,nativeImage:nativeImage,nativeTheme:nativeTheme};};}};
          throw Error(name);
        }};
        function setTimeout(fn,delay){scheduled.push({fn:fn,delay:delay});return scheduled.length;}
        function clearTimeout(id){if(scheduled[id-1])scheduled[id-1].cancelled=true;}
        """)
        let command: [String: Any] = ["owner":"test", "action":"update", "pid":123,
            "executable":"/test/App", "package":"/test/package.json", "light":"light.png", "dark":"dark.png", "original":"original.png"]
        context.evaluateScript(try ElectronDockClient.expression(command))
        XCTAssertNil(scriptError)
        XCTAssertEqual(context.evaluateScript("currentIcon.path")?.toString(), "light.png")
        context.evaluateScript("app.dock.setIcon({path:'app-new.png'});")
        XCTAssertEqual(context.evaluateScript("currentIcon.path")?.toString(), "light.png")
        context.evaluateScript("nativeTheme.shouldUseDarkColorsForSystemIntegratedUI=true;listeners.updated();")
        XCTAssertEqual(context.evaluateScript("currentIcon.path")?.toString(), "dark.png")
        var restore = command; restore["action"] = "restore"
        context.evaluateScript(try ElectronDockClient.expression(restore))
        XCTAssertNil(scriptError)
        XCTAssertEqual(context.evaluateScript("currentIcon.path")?.toString(), "app-new.png")
        XCTAssertEqual(context.evaluateScript("app.dock.setIcon===originalSetIcon && !globalThis.__aiQuotaDock && !listeners.updated")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("scheduled.filter(function(t){return t.delay===100;}).length")?.toInt32(), 2)
    }
    func testRejectsWrongProcessAndStillSchedulesInspectorClose() throws {
        let context = JSContext()!
        context.evaluateScript("""
        var scheduled=[];function setTimeout(fn,ms){scheduled.push(ms);}
        var process={pid:999,execPath:'/wrong',getBuiltinModule:function(name){
          return name==='inspector'?{close:function(){}}:{createRequire:function(){return function(){return {app:{},nativeImage:{},nativeTheme:{}};};}};
        }};
        """)
        var error: String?
        context.exceptionHandler = { _, value in error = value?.toString() }
        context.evaluateScript(try ElectronDockClient.expression(["pid":123,"executable":"/test/App","package":"/test/package.json"]))
        XCTAssertTrue(error?.contains("应用身份不匹配") == true)
        context.exception = nil
        XCTAssertEqual(context.evaluateScript("scheduled[0]")?.toInt32(), 100)
    }
}
