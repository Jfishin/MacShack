const pageSize = 0x4000n;
const hex64 = value => {
    let result = '';
    for (let i = 0; i < 8; i++, value >>= 8n)
        result += Number(value & 255n).toString(16).padStart(2, '0');
    return result;
};
const register = (packet, name) => {
    const match = new RegExp(`(?:^|;)${name}:([0-9a-f]{16});`, 'i').exec(packet);
    if (!match) throw new Error(`Missing register ${name}`);
    return BigInt('0x' + match[1].match(/../g).reverse().join(''));
};
const checked = command => {
    const response = send_command(command);
    if (response !== 'OK') throw new Error(`${command.split(':')[0]} failed: ${response}`);
};

function prepare(address, length) {
    if (length <= 0n || (length % pageSize) !== 0n || length > (1n << 30n))
        throw new Error('Invalid prepare length');
    const allocated = address === 0n;   // fresh debugger pages are zero: write 00 without reading them first
    if (allocated) {
        const reply = send_command(`_M${length.toString(16)},rx`);
        if (!/^[0-9a-f]+$/i.test(reply) || /^E[0-9a-f]{2}$/i.test(reply))
            throw new Error(`RX allocation failed: ${reply}`);
        address = BigInt('0x' + reply);
    }
    if (address === 0n || (address % pageSize) !== 0n || address + length > (1n << 64n))
        throw new Error('Invalid prepare address');
    // One 2-byte write straddling a page boundary touches both pages: half the round trips again.
    if (allocated) {
        let page = address;
        for (; page + pageSize < address + length; page += 2n * pageSize) checked(`M${(page + pageSize - 1n).toString(16)},2:0000`);
        if (page < address + length) checked(`M${page.toString(16)},1:00`);
        return address;
    }
    for (let page = address; page < address + length; page += pageSize) {
        const byte = send_command(`m${page.toString(16)},1`);
        if (!/^[0-9a-f]{2}$/i.test(byte)) throw new Error(`Page read failed: ${byte}`);
        checked(`M${page.toString(16)},1:${byte}`);
    }
    return address;
}

const pid = get_pid();
const attach = send_command(`vAttach;${pid.toString(16)}`);
if (!/^T[0-9a-f]{2}/i.test(attach)) throw new Error(`Attach failed: ${attach}`);
log(`MacShack JIT: attached to ${pid}; preserving page contents`);
log(`Ignored exceptions: ${send_command('QSetIgnoredExceptions:EXC_BAD_ACCESS;EXC_BAD_INSTRUCTION')}`);
log(`Pass signals: ${send_command('QPassSignals:' + Array.from({length: 31}, (_, i) => i + 1)
    .filter(signal => signal !== 5).map(signal => signal.toString(16)).join(';'))}`);
let pending = null;
let faultLogs = 0;
while (true) {
    const packet = pending === null ? send_command('c') : pending;
    pending = null;
    if (/^[WX]/.test(packet)) { log(`MacShack exited: ${packet}`); break; }
    if (!/^T[0-9a-f]{2}/i.test(packet)) throw new Error(`Unexpected stop: ${packet}`);
    const thread = /(?:^T[0-9a-f]{2}|;)thread:([0-9a-f]+);/i.exec(packet);
    if (!thread) throw new Error('Stop has no thread');
    const tid = thread[1];
    const kind = /;metype:([0-9a-f]+);/i.exec(packet);
    const metype = kind ? parseInt(kind[1], 16) : 0;
    const data = Array.from(packet.matchAll(/;medata:([0-9a-f]+)(?=;)/gi), match => parseInt(match[1], 16));
    let signal = parseInt(packet.slice(1, 3), 16);
    if (metype === 5 && data[0] === 0x10003) signal = data[1];
    else if (metype === 1) signal = data[0] === 1 ? 11 : 10;
    else if (metype === 2) signal = 4;
    else if (metype === 3) signal = 8;
    else if (metype === 11) continue;

    if (signal === 5 && (metype === 0 || metype === 6)) {
        const pc = register(packet, '20');
        const instruction = send_command(`m${pc.toString(16)},4`);
        if (instruction.toLowerCase() === 'a0013ed4') {
            const command = register(packet, '10');
            if (command === 0n || command === 1n) {
                checked(`P20=${hex64(pc + 4n)};thread:${tid};`);
                if (command === 0n) {
                    checked('D');
                    log('MacShack JIT: detached');
                    break;
                }
                let address = 0n;
                try { address = prepare(register(packet, '00'), register(packet, '01')); }
                catch (error) { log(`MacShack prepare failed: ${error.message}`); }
                checked(`P0=${hex64(address)};thread:${tid};`);
                continue;
            }
        }
    }
    if (!Number.isInteger(signal) || signal < 1 || signal > 31)
        throw new Error(`Invalid signal in ${packet}`);
    if (faultLogs++ < 8) log(`MacShack JIT: forwarding signal ${signal} on thread ${tid}`);
    pending = send_command(`vCont;C${signal.toString(16).padStart(2, '0')}:${tid};c`);
    if (!/^[TWX]/.test(pending)) throw new Error(`Signal forwarding failed: ${pending}`);
}
