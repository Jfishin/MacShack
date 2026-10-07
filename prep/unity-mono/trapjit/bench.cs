using System; using System.Reflection; using System.Runtime.CompilerServices; using System.Diagnostics;
class B { static void Main(string[] a) {
  var sw = Stopwatch.StartNew(); int ok = 0, bad = 0;
  foreach (var name in a) {
    var asm = Assembly.LoadFrom(name);
    Type[] ts; try { ts = asm.GetTypes(); } catch (ReflectionTypeLoadException e) { ts = e.Types; }
    foreach (var t in ts) { if (t == null || t.ContainsGenericParameters) continue;
      foreach (var m in t.GetMethods(BindingFlags.DeclaredOnly|BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance|BindingFlags.Static)) {
        if (m.IsAbstract || m.ContainsGenericParameters || m.GetMethodBody() == null) continue;
        try { if (m.MethodHandle.GetFunctionPointer() != IntPtr.Zero) ok++; else bad++; } catch { bad++; } } } }
  Console.WriteLine("bench jitted " + ok + " failed " + bad + " in " + sw.ElapsedMilliseconds + " ms");
} }
