using System;
using System.Collections.Generic;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection.Emit;
using System.Threading;
using System.Threading.Tasks;
interface IShape { double Area(); string Name<T>(T tag); }
struct Sq : IShape { public double s; public double Area() => s * s; public string Name<T>(T t) => "sq" + t; }
class Ci : IShape { public double r; public double Area() => 3.14159 * r * r; public virtual string Name<T>(T t) => "ci" + t; }
class Ci2 : Ci { public override string Name<T>(T t) => "ci2" + t; }
struct Pair<T, U> { public T a; public U b; public override string ToString() => a + "/" + b; }
static class G { public static int Sum<T>(IEnumerable<T> xs, Func<T, int> f) { int s = 0; foreach (var x in xs) s += f(x); return s; } }
class P {
    static int Big(int x) { switch (x % 37) { case 0: return 1; case 1: return 3; case 2: return 5; case 3: return 7; case 5: return 11; case 8: return 13; case 13: return 17; case 21: return 19; case 34: return 23; default: return x & 31; } }
    static int Rec(int n) => n < 2 ? n : Rec(n - 1) + Rec(n - 2);
    static async Task<int> Aw(int n) { await Task.Yield(); return n * 2; }
    static void Main() {
        long s = 0;
        var shapes = new List<IShape>(); for (int i = 0; i < 300; i++) shapes.Add(i % 3 == 0 ? (IShape)new Sq { s = i } : i % 3 == 1 ? new Ci { r = i } : new Ci2 { r = i });
        foreach (var sh in shapes) s += (long)sh.Area() + sh.Name(1).Length + sh.Name("x").Length + sh.Name(2.5).Length;
        for (int i = 0; i < 300000; i++) s += Big(i);
        s += Rec(22);
        var pairs = Enumerable.Range(0, 1000).Select(i => new Pair<int, string> { a = i, b = "v" + i }).ToList();
        s += pairs.Sum(p => p.ToString().Length) + G.Sum(pairs, p => p.a) + G.Sum(pairs.Select(p => (long)p.a), x => (int)x);
        for (int i = 0; i < 20000; i++) { try { if (i % 3 == 0) throw new ArgumentException("e" + i); if (i % 5 == 0) { object o = null; o.ToString(); } } catch (ArgumentException e) when (e.Message.Length > 1) { s++; } catch (NullReferenceException) { s += 2; } }
        var dm = new DynamicMethod("add", typeof(int), new[] { typeof(int), typeof(int) });
        var il = dm.GetILGenerator(); il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldarg_1); il.Emit(OpCodes.Add); il.Emit(OpCodes.Ret);
        var add = (Func<int, int, int>)dm.CreateDelegate(typeof(Func<int, int, int>));
        for (int i = 0; i < 200; i++) { var d2 = new DynamicMethod("m" + i, typeof(int), new[] { typeof(int) }); var g = d2.GetILGenerator(); g.Emit(OpCodes.Ldarg_0); g.Emit(OpCodes.Ldc_I4, i); g.Emit(OpCodes.Mul); g.Emit(OpCodes.Ret); s += ((Func<int, int>)d2.CreateDelegate(typeof(Func<int, int>)))(3); }
        s += add(40, 2);
        Expression<Func<int, int>> ex = x => x * x + 1; s += ex.Compile()(9);
        var threads = new Thread[8]; long ts = 0;
        for (int t = 0; t < 8; t++) { int tt = t; threads[t] = new Thread(() => { long l = 0; for (int i = 0; i < 100000; i++) l += Big(i + tt) + new Pair<int, int> { a = i, b = tt }.a; Interlocked.Add(ref ts, l); }); threads[t].Start(); }
        foreach (var t in threads) t.Join(); s += ts;
        s += Aw(21).GetAwaiter().GetResult();
        s += string.Join(",", pairs.Take(5)).Length + $"{s:X}".Length;
        Console.WriteLine("stress ok " + s);
    }
}
