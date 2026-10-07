const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(`${__dirname}/macshack-jit.js`, 'utf8');
const le = value => Buffer.from(BigInt(value).toString(16).padStart(16, '0'), 'hex').reverse().toString('hex');
const stop = (command, address = 0n, length = 0x4000n) =>
    `T05thread:1;00:${le(address)};01:${le(length)};10:${le(command)};20:${le(0x100004000n)};metype:6;`;
const fault = 'T0bthread:1;metype:1;medata:2;medata:0;';

function run(stops, failWrite = false, byte = 'a5') {
    const commands = [], logs = [];
    let resumes = 0;
    vm.runInNewContext(source, {
        get_pid: () => 42,
        log: message => logs.push(message),
        send_command: command => {
            commands.push(command);
            if (command === 'vAttach;2a') return 'T05thread:1;';
            if (command === 'c' || command.startsWith('vCont;')) {
                assert.ok(resumes < stops.length, 'Unexpected resume lost a stop response');
                return stops[resumes++];
            }
            if (command.startsWith('Q') || command.startsWith('P') || command === 'D') return 'OK';
            if (command.startsWith('_M')) return '7012340000';
            if (command === 'm100004000,4') return 'a0013ed4';
            if (/^m[0-9a-f]+,1$/.test(command)) return byte;
            if (/^M[0-9a-f]+,[12]:[0-9a-f]{2,4}$/.test(command)) return failWrite ? 'E09' : 'OK';
            assert.fail(`Unexpected command: ${command}`);
        }
    }, {timeout: 1000});
    assert.equal(resumes, stops.length);
    return {commands, logs};
}

const first = run([stop(1n, 0x7012340000n, 0x8000n), fault, stop(1n), stop(0n)]);
assert.ok(first.commands.includes('M7012340000,1:a5'));
assert.ok(first.commands.includes('M7012344000,1:a5'));
assert.ok(first.commands.includes(`P0=${le(0x7012340000n)};thread:1;`));
assert.ok(first.commands.includes('vCont;C0a:1;c'));
assert.equal(first.commands.filter(command => command === 'c').length, 3);
assert.equal(first.commands.at(-1), 'D');

const failed = run([stop(1n, 0x100008000n), stop(0n)], true);
assert.ok(failed.commands.includes('P0=0000000000000000;thread:1;'));
assert.ok(failed.logs.some(line => line.includes('prepare failed')));
for (const [address, length] of [[0x100008001n, 0x4000n], [0x100008000n, 1n], [0n, 0n]]) {
    const invalid = run([stop(1n, address, length), stop(0n)]);
    assert.ok(invalid.commands.includes('P0=0000000000000000;thread:1;'));
    assert.ok(!invalid.commands.some(command => /^M/.test(command)));
}
const soft = run(['T05thread:1;metype:5;medata:10003;medata:1e;', stop(0n)]);
assert.ok(soft.commands.includes('vCont;C1e:1;c'));
const unreadable = run([stop(1n, 0x100008000n), stop(0n)], false, 'E01');
assert.ok(unreadable.commands.includes('P0=0000000000000000;thread:1;'));
assert.ok(!unreadable.commands.some(command => /^M/.test(command)));
const pool = run([stop(1n, 0n, 0x8000n), stop(0n)]);
assert.ok(pool.commands.includes('_M8000,rx'));
assert.ok(pool.commands.includes('M7012343fff,2:0000'));   // both pages in one write
assert.equal(pool.commands.filter(command => /^M/.test(command)).length, 1);
assert.ok(!pool.commands.some(command => /^m7012/.test(command)));
assert.ok(pool.commands.includes(`P0=${le(0x7012340000n)};thread:1;`));
run(['W00']);
console.log('JIT script checks passed: preserved bytes, write-only debugger pools, 64-bit addresses, fault/soft-signal forwarding, pending stops, failures, detach and exit.');
