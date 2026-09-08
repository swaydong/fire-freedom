import Foundation

public enum CodexEphemeralThreadPurpose: Sendable {
    case financialAnalysis
    case assetRecognition
}

public enum CodexRequestBuilder {
    public static let developerInstructions = """
    你是 F.I.R.E「自由进度」应用内的个人财务分析器。
    只能使用本会话中由应用提交的 AnalysisPacketV1 数据，不得调用工具、联网、读取文件或引用外部事实。
    事实通过 evidenceRefs 保持可追溯；正文只写对用户有用的判断，不写审计过程、内部字段名或模板化前缀。
    不得猜测缺失数据。
    涉及具体消费时，只能选择数据包中的真实流水 fingerprint；不得编造日期、商户、分类或金额。
    不得提供具体证券、基金或其他金融产品的买入、卖出、择时和仓位指令。
    必须严格按本次请求提供的 JSON Schema 输出，不要添加 Markdown 或 Schema 之外的字段。
    """

    public static let assetRecognitionDeveloperInstructions = """
    你是 F.I.R.E「自由进度」应用内的资产 OCR 语义整理器。
    只能使用本会话提交的 OCR 文本、置信度和归一化坐标，不得调用工具、联网、读取文件或引用外部事实。
    不得猜测截图中没有出现的产品代码、币种、类型或金额；无法确认代码时必须返回 null。
    必须严格按本次请求提供的 JSON Schema 输出，不要添加 Markdown 或 Schema 之外的字段。
    """

    public static let hardenedConfig: JSONValue = .object([
        "web_search": .string("disabled"),
        "features": .object([
            "apps": .bool(false),
            "artifact": .bool(false),
            "auth_elicitation": .bool(false),
            "browser_use": .bool(false),
            "browser_use_external": .bool(false),
            "browser_use_full_cdp_access": .bool(false),
            "chronicle": .bool(false),
            "computer_use": .bool(false),
            "code_mode": .bool(false),
            "code_mode_host": .bool(false),
            "default_mode_request_user_input": .bool(false),
            "enable_mcp_apps": .bool(false),
            "external_agent_memory_import": .bool(false),
            "goals": .bool(false),
            "hooks": .bool(false),
            "image_generation": .bool(false),
            "in_app_browser": .bool(false),
            "memories": .bool(false),
            "multi_agent": .bool(false),
            "multi_agent_v2": .bool(false),
            "plugins": .bool(false),
            "remote_plugin": .bool(false),
            "request_permissions_tool": .bool(false),
            "shell_snapshot": .bool(false),
            "shell_tool": .bool(false),
            "skill_mcp_dependency_install": .bool(false),
            "skill_search": .bool(false),
            "standalone_web_search": .bool(false),
            "tool_suggest": .bool(false),
            "tool_call_mcp_elicitation": .bool(false),
            "unified_exec": .bool(false),
            "workspace_dependencies": .bool(false),
        ]),
        "agents": .object([
            "enabled": .bool(false),
        ]),
        "mcp_servers": .object([:]),
    ])

    public static func initialize(id: Int) -> JSONRPCRequest {
        return JSONRPCRequest(
            id: id,
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("fire-freedom-bridge"),
                    "title": .string("F.I.R.E 自由进度"),
                    "version": .string("1.0"),
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(true),
                ]),
            ])
        )
    }

    public static func initialized() -> JSONRPCNotification {
        JSONRPCNotification(method: "initialized", params: nil)
    }

    public static func startThread(id: Int, cwd: URL) -> JSONRPCRequest {
        JSONRPCRequest(
            id: id,
            method: "thread/start",
            params: .object([
                "approvalPolicy": .string("never"),
                "sandbox": .string("read-only"),
                "cwd": .string(cwd.path),
                "ephemeral": .bool(false),
                "developerInstructions": .string(developerInstructions),
                "config": hardenedConfig,
            ])
        )
    }

    public static func startEphemeralThread(
        id: Int,
        cwd: URL,
        purpose: CodexEphemeralThreadPurpose
    ) -> JSONRPCRequest {
        let instructions = switch purpose {
        case .financialAnalysis:
            developerInstructions
        case .assetRecognition:
            assetRecognitionDeveloperInstructions
        }
        return JSONRPCRequest(
            id: id,
            method: "thread/start",
            params: .object([
                "approvalPolicy": .string("never"),
                "sandbox": .string("read-only"),
                "cwd": .string(cwd.path),
                "ephemeral": .bool(true),
                "developerInstructions": .string(instructions),
                "config": hardenedConfig,
            ])
        )
    }

    public static func resumeThread(id: Int, threadID: String, cwd: URL) -> JSONRPCRequest {
        JSONRPCRequest(
            id: id,
            method: "thread/resume",
            params: .object([
                "threadId": .string(threadID),
                "approvalPolicy": .string("never"),
                "sandbox": .string("read-only"),
                "cwd": .string(cwd.path),
                "developerInstructions": .string(developerInstructions),
                "config": hardenedConfig,
            ])
        )
    }

    public static func deleteThread(id: Int, threadID: String) -> JSONRPCRequest {
        JSONRPCRequest(
            id: id,
            method: "thread/delete",
            params: .object([
                "threadId": .string(threadID),
            ])
        )
    }

    public static func unsubscribeThread(
        id: Int,
        threadID: String
    ) -> JSONRPCRequest {
        JSONRPCRequest(
            id: id,
            method: "thread/unsubscribe",
            params: .object([
                "threadId": .string(threadID),
            ])
        )
    }

    public static func interruptTurn(
        id: Int,
        threadID: String,
        turnID: String
    ) -> JSONRPCRequest {
        JSONRPCRequest(
            id: id,
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
    }

    public static func reportTurn(
        id: Int,
        threadID: String,
        packetJSON: String
    ) -> JSONRPCRequest {
        let prompt = """
        请分析下面的 AnalysisPacketV1，并生成 AnalysisReportV1。
        优先围绕 monthlySummary 指定月份分析；其中收入、生活支出、支出退款、净结余和资产汇总由本地确定性计算，
        不得自行重新加总或改写。spendingAnalysis 中的大类异动、大额支出和异常单笔也由本机确定性计算，
        必须直接使用，不得重新判定或虚构；transactions 的滚动数据只用于解释原因和提供证据。
        evidence 中每条证据必须有唯一 id；若证据来自流水，
        transactionFingerprints 必须逐字复制数据包中真实存在的 fingerprint 字段，不能填写流水 id。
        dataConfidence、findings 和 actions 的 evidenceRefs 只能引用上述 evidence id。
        dataConfidence.level 必须原样使用 fireState.confidence，不得自行提高或降低。
        输出应像本人会反复看的财务简报，不是审计报告：
        - coreConclusion 只写 1 句、最多 60 字：给出一个明确判断、最多两个关键数字和最大的影响因素。
        - spendingFindings 写 0–3 条，优先解释 spendingAnalysis 中影响最大的一级分类增减和异常单笔；确实没有异动或异常才返回空数组。
        - assetStructureRisks、fireDrivers 各 0–1 条；只有相对月度摘要存在新增信息时才写，没有就返回空数组。
        - actions 只写真正值得执行的 1–2 条，按影响排序；不得为了凑数给出泛泛建议，也不得包含具体买卖指令。
        - 收支分析先区分固定义务、一次性支出和可调整消费，再解释本机给出的大类变化、商户和金额变化；不要套用通用消费比例。
        - 若本月有生活支出，选择 1–3 笔最能解释结余或支出结构的真实消费。优先选择单笔金额不低于 2,000 元且不低于本月生活支出 10% 的交易；若没有，再选择本月金额最高的一笔。
        - 具体消费只能来自 monthlySummary 月份内、direction=expense 且未被转账、投资买卖、贷款本金、重复流水或计入标志排除的交易。
        - 每笔具体消费都必须放入 evidence.transactionFingerprints；evidence.value 使用“月日 · 商户或分类 · 金额”格式。消费相关 action 必须引用这些 evidence，由客户端展示真实流水。
        - action 的 rationale 只解释为什么值得处理以及应确认一次性还是持续性，不要重复抄写消费清单，也不要只写“减少消费”。
        - dataConfidence.explanation 只说明最关键的数据缺口，不复述结论或指标。
        - 除 evidence 外的中文正文总计不超过 350 字；同一个数字或判断只出现一次。
        - 禁止使用“整体来看”“建议关注”“持续关注”“合理规划”“稳步推进”“定期复盘”“已观察”“计算”“限制”等套话或模板前缀。
        - 金额使用元或万元并合理取整，比例保留 1 位小数，日期只写年月；不要输出长小数或 ISO 时间。
        - 不罗列其余普通单笔消费；同一笔交易只引用一次。
        - evidence 尽量复用，总数不超过 6 条；limitations 最多 1 条，且不得与 dataConfidence.explanation 重复。

        AnalysisPacketV1:
        \(packetJSON)
        """
        return turn(
            id: id,
            threadID: threadID,
            text: prompt,
            outputSchema: AnalysisOutputSchema.reportV1,
            effort: "low"
        )
    }

    public static func answerTurn(
        id: Int,
        threadID: String,
        question: String,
        contextJSON: String? = nil
    ) -> JSONRPCRequest {
        let prompt: String
        if let contextJSON {
            prompt = """
            请根据下面由 F.I.R.E 本机恢复的已脱敏报告上下文回答 currentQuestion。
            packet 中的确定性汇总不得自行改写；report 是已经生成并校验的报告；
            previousFollowUps 是本报告此前的追问记录。
            evidenceRefs 只能使用 report.evidence 中已有的 id。
            若问题要求具体买卖指令，请拒绝该部分、设置 refusedInvestmentInstruction=true 并解释限制。

            AnalysisFollowUpContextV1:
            \(contextJSON)
            """
        } else {
            prompt = """
            用户在同一份财务报告下追问：
            \(question)

            只能引用本会话已经提供的数据回答，evidenceRefs 只能使用上一份报告已有的 evidence id。
            若问题要求具体买卖指令，请拒绝该部分、设置 refusedInvestmentInstruction=true 并解释限制。
            """
        }
        return turn(
            id: id,
            threadID: threadID,
            text: prompt,
            outputSchema: AnalysisOutputSchema.answerV1
        )
    }

    public static func recognizeAssetsTurn(
        id: Int,
        threadID: String,
        requestJSON: String
    ) -> JSONRPCRequest {
        let prompt = """
        请把下面的 RecognizeAssetsRequestV1 OCR 行整理为 RecognizeAssetsResponseV1。
        boundingBox 是 Apple Vision 的归一化坐标，原点在左下角。只能在同一 imageIndex 内根据相邻位置建立产品、代码和市值关系。
        优先按几何位置配对：产品名称通常在左列，当前金额或市值通常在同一水平行的中间列；右列的负数和百分比通常是收益，必须忽略。
        产品名称被 OCR 拆成上下相邻的多行时应合并。只要名称和同一行的正数市值能够可靠配对，就必须返回该持仓，不能因为产品代码缺失而省略。
        positions 只返回真实持仓产品；不要把总资产、账户余额、收益、收益率、成本、净值、单价、份额或日期当成产品市值。
        同一产品在不同截图出现时仍逐截图返回，由应用按产品代码汇总。
        productCode 无法从 OCR 文本确认时返回 null；不得凭模型知识补全代码。如果 productCode 非 null，evidence 必须包含截图 OCR 中出现的该代码原文，目录补全由应用完成。kind 只能是 fund、stock、cash；currency 只能是 CNY、USD、HKD。
        kind 可以根据页面标题、产品名称和栏目标签推断。中文基金持仓页未出现外币符号或海外市场币种时，currency 暂按 CNY 并降低 confidence，用户会在应用内确认修正；不要因此返回空 positions。
        originalMarketValue 必须是截图中的当前持有金额或市值，必须大于 0。
        confidence 表示产品名称、代码、币种和市值配对的整体可信度，范围为 0–1。
        evidence 使用简短的原始 OCR 文本说明依据，不得添加截图中不存在的信息。

        RecognizeAssetsRequestV1:
        \(requestJSON)
        """
        return turn(
            id: id,
            threadID: threadID,
            text: prompt,
            outputSchema: AssetRecognitionOutputSchema.responseV1,
            effort: "low"
        )
    }

    private static func turn(
        id: Int,
        threadID: String,
        text: String,
        outputSchema: JSONValue,
        effort: String? = nil
    ) -> JSONRPCRequest {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "approvalPolicy": .string("never"),
            "sandboxPolicy": .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(false),
            ]),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                    "text_elements": .array([]),
                ]),
            ]),
            "outputSchema": outputSchema,
        ]
        if let effort {
            params["effort"] = .string(effort)
        }
        return JSONRPCRequest(
            id: id,
            method: "turn/start",
            params: .object(params)
        )
    }
}

public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public let id: Int
    public let method: String
    public let params: JSONValue

    public init(id: Int, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Codable, Equatable, Sendable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue?) {
        self.method = method
        self.params = params
    }
}

struct JSONRPCInbound: Decodable, Sendable {
    struct RPCError: Decodable, Sendable {
        let code: Int?
        let message: String
        let data: JSONValue?
    }

    let id: JSONValue?
    let result: JSONValue?
    let error: RPCError?
    let method: String?
    let params: JSONValue?
}
