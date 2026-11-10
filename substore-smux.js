function operator(proxies, targetPlatform, context = {}) {
    if (!Array.isArray(context.raw)) {
        throw new Error('原始订阅内容不可用，请在单条订阅中添加此脚本处理');
    }
    const sources = context.raw || [];
    for (const source of sources) {
        let content = typeof source === 'string' ? source : source?.content;
        if (typeof content !== 'string') continue;
        content = content.trim();
        if (!content.includes('://') && /^[A-Za-z0-9+/=_\s-]+$/.test(content)) {
            content = b64d(content.replace(/\s/g, ''));
        }
        for (const line of content.split(/\r?\n/)) {
            const uri = line.trim();
            if (!uri.startsWith('ss://')) continue;
            const query = uri.split('#')[0].split('?')[1] || '';
            const parameter = query.split('&').find(item => item.startsWith('smux='));
            if (!parameter) continue;
            let smux;
            try {
                smux = JSON.parse(decodeURIComponent(parameter.slice(5)));
                if (!smux || Array.isArray(smux) || typeof smux !== 'object' ||
                    typeof smux.enabled !== 'boolean') throw new Error();
            } catch (_) {
                throw new Error('SS smux 参数无效');
            }
            const original = ProxyUtils.parse(uri)[0];
            if (!original) throw new Error('SS 节点链接无法解析');
            const candidates = proxies.filter(proxy =>
                proxy.type === 'ss' && proxy.name === original.name &&
                proxy.server === original.server && Number(proxy.port) === Number(original.port) &&
                proxy.cipher === original.cipher && proxy.password === original.password &&
                JSON.stringify(proxy['plugin-opts']) === JSON.stringify(original['plugin-opts']));
            for (const proxy of candidates) {
                proxy.smux = JSON.parse(JSON.stringify(smux));
            }
        }
    }
    return proxies;
}
