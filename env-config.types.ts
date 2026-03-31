/**
 * ad2nx 自动安装环境变量配置 - TypeScript 类型定义
 * 用于前端表单和后端 API 对接
 * 
 * @version 1.0.0
 * @date 2026-03-31
 */

// ==================== 枚举定义 ====================

/** 核心类型 */
export enum CoreType {
  /** Xray 核心 - 支持 V2Ray 全协议 */
  Xray = 1,
  /** Sing-box 核心 - 高性能（推荐） */
  Singbox = 2,
  /** Hysteria2 核心 - 基于 QUIC */
  Hysteria2 = 3,
}

/** 传输协议类型 */
export enum NodeType {
  /** Shadowsocks - 轻量级加密代理 */
  Shadowsocks = 1,
  /** VLESS - 轻量级协议（推荐） */
  Vless = 2,
  /** VMess - V2Ray 原生协议 */
  Vmess = 3,
  /** Hysteria v1 */
  Hysteria = 4,
  /** Hysteria v2 */
  Hysteria2 = 5,
  /** Trojan - 伪装 HTTPS */
  Trojan = 6,
  /** TUIC - 基于 QUIC */
  Tuic = 7,
  /** AnyTLS - 通用 TLS 隧道 */
  AnyTLS = 8,
}

/** 节点运行模式 */
export enum NodeInoutType {
  /** 独立节点 */
  Stand = 'stand',
  /** 入站节点（需要出口服务器） */
  In = 'in',
  /** 出站节点 */
  Out = 'out',
}

/** 证书模式 */
export enum CertMode {
  /** 无证书 */
  None = 'none',
  /** HTTP-01 自动申请 */
  Http = 'http',
  /** DNS-01 自动申请 */
  Dns = 'dns',
  /** 自签名证书 */
  Self = 'self',
}

/** 是/否选项 */
export enum YesNo {
  Yes = 'y',
  No = 'n',
}

// ==================== 接口定义 ====================

/**
 * 必填配置参数
 */
export interface RequiredConfig {
  /** 
   * API 服务器地址
   * @example "api.example.com"
   */
  API_HOST: string;
  
  /** 
   * API 密钥（认证令牌）
   * @sensitive true
   */
  API_KEY: string;
  
  /** 
   * 节点 ID（正整数）
   * @minimum 1
   * @maximum 999999
   */
  NODE_ID: number;
  
  /** 
   * 核心类型
   * @default 2 (Singbox)
   */
  CORE_TYPE: CoreType;
}

/**
 * 节点配置参数
 */
export interface NodeConfig {
  /** 
   * 传输协议类型
   * @default 2 (Vless)
   */
  NODE_TYPE?: NodeType;
  
  /** 
   * 节点运行模式
   * @default "stand"
   */
  NODE_INOUT_TYPE?: NodeInoutType;
  
  /** 
   * 出口节点地址（仅 NODE_INOUT_TYPE=in 时需要）
   * @example "out-node.example.com:443"
   */
  NODE_OUT_SERVER?: string;
}

/**
 * 证书配置参数
 */
export interface CertConfig {
  /** 
   * 证书模式
   * @default "none"
   */
  CERT_MODE?: CertMode;
  
  /** 
   * 证书域名
   * @default "example.com"
   */
  CERT_DOMAIN?: string;
}

/**
 * 自动化配置参数
 */
export interface AutomationConfig {
  /** 
   * 是否自动生成配置文件
   * @default "y"
   */
  IF_GENERATE?: YesNo;
  
  /** 
   * 是否执行注册脚本
   * @default "n"
   * @requires python3
   */
  IF_REGISTER?: YesNo;
}

/**
 * Reality 高级配置参数
 * 仅当 NODE_TYPE=2 (Vless) 且 NODE_TYPE2="reality" 时有效
 */
export interface RealityConfig {
  /** 
   * Reality 模式标识
   * @example "reality"
   */
  NODE_TYPE2?: '' | 'reality';
  
  /** 
   * Reality UUID
   * @pattern ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$
   */
  UUID_AB?: string;
  
  /** 
   * Reality Short ID
   * @pattern ^[0-9a-fA-F]{1,16}$
   */
  SHORT_ID?: string;
  
  /** 
   * Reality 伪装域名
   * @default "www.apple.com"
   */
  REALITY_SERVER_NAME?: string;
}

/**
 * GitHub 配置参数
 */
export interface GithubConfig {
  /** 
   * GitHub 访问令牌
   * @sensitive true
   * @pattern ^ghp_[a-zA-Z0-9]{36}$
   */
  GITHUB_TOKEN?: string;
  
  /** 
   * Release 仓库
   * @default "Lawer09/ad2nx"
   */
  RELEASE_REPO?: string;
  
  /** 
   * 脚本仓库
   * @default "Lawer09/ad2nx-s"
   */
  SCRIPT_REPO?: string;
  
  /** 
   * 脚本分支
   * @default "master"
   */
  SCRIPT_BRANCH?: string;
}

/**
 * 完整的环境变量配置
 */
export interface EnvConfig extends 
  RequiredConfig,
  NodeConfig,
  CertConfig,
  AutomationConfig,
  RealityConfig,
  GithubConfig {}

// ==================== 表单字段元数据 ====================

/**
 * 字段依赖配置
 */
export interface FieldDependency {
  /** 依赖的字段名 */
  field: string;
  /** 依赖的值（显示条件） */
  value?: string | number;
  /** 不等于该值时显示 */
  notValue?: string | number;
}

/**
 * 枚举选项配置
 */
export interface EnumOption {
  /** 值 */
  value: string | number;
  /** 显示标签 */
  label: string;
  /** 详细描述 */
  description?: string;
}

/**
 * 表单字段配置
 */
export interface FormField {
  /** 字段名 */
  name: keyof EnvConfig;
  /** 显示标题 */
  title: string;
  /** 字段描述 */
  description: string;
  /** 数据类型 */
  type: 'string' | 'integer' | 'boolean';
  /** 是否必填 */
  required: boolean;
  /** 默认值 */
  defaultValue?: string | number;
  /** 占位符 */
  placeholder?: string;
  /** 是否敏感数据（密码形式显示） */
  sensitive?: boolean;
  /** 枚举选项 */
  options?: EnumOption[];
  /** 验证正则 */
  pattern?: string;
  /** 最小值（数字）/ 最小长度（字符串） */
  min?: number;
  /** 最大值（数字）/ 最大长度（字符串） */
  max?: number;
  /** 字段依赖 */
  dependsOn?: FieldDependency;
  /** 所属分组 */
  group: string;
  /** 排序顺序 */
  order: number;
}

/**
 * 表单分组配置
 */
export interface FormGroup {
  /** 分组标识 */
  key: string;
  /** 分组标题 */
  title: string;
  /** 分组描述 */
  description: string;
  /** 排序顺序 */
  order: number;
  /** 是否默认折叠 */
  collapsed: boolean;
}

// ==================== 表单字段定义 ====================

export const formGroups: FormGroup[] = [
  { key: 'required', title: '必填配置', description: '安装必需的核心参数', order: 1, collapsed: false },
  { key: 'node', title: '节点配置', description: '节点运行模式和协议设置', order: 2, collapsed: false },
  { key: 'certificate', title: '证书配置', description: 'TLS 证书相关设置', order: 3, collapsed: false },
  { key: 'automation', title: '自动化选项', description: '配置生成和注册相关选项', order: 4, collapsed: false },
  { key: 'advanced', title: '高级配置', description: 'Reality 等高级功能配置', order: 5, collapsed: true },
  { key: 'github', title: 'GitHub 配置', description: '下载源和认证相关设置', order: 6, collapsed: true },
];

export const formFields: FormField[] = [
  // ===== 必填配置 =====
  {
    name: 'API_HOST',
    title: 'API 服务器地址',
    description: '后端 API 服务器的域名或 IP 地址，不包含协议前缀',
    type: 'string',
    required: true,
    placeholder: 'api.example.com',
    pattern: '^[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]$',
    min: 3,
    max: 253,
    group: 'required',
    order: 1,
  },
  {
    name: 'API_KEY',
    title: 'API 密钥',
    description: '用于节点认证的 API 密钥，从控制面板获取',
    type: 'string',
    required: true,
    placeholder: 'your-secret-api-key',
    sensitive: true,
    min: 8,
    max: 256,
    group: 'required',
    order: 2,
  },
  {
    name: 'NODE_ID',
    title: '节点 ID',
    description: '节点的唯一标识符，必须是正整数',
    type: 'integer',
    required: true,
    placeholder: '1',
    min: 1,
    max: 999999,
    group: 'required',
    order: 3,
  },
  {
    name: 'CORE_TYPE',
    title: '核心类型',
    description: '代理核心引擎类型',
    type: 'integer',
    required: true,
    defaultValue: 2,
    options: [
      { value: 1, label: 'Xray', description: 'Xray 核心 - 支持 V2Ray 全协议，稳定性好' },
      { value: 2, label: 'Sing-box', description: 'Sing-box 核心 - 高性能，支持多种协议（推荐）' },
      { value: 3, label: 'Hysteria2', description: 'Hysteria2 核心 - 基于 QUIC，适合高延迟网络' },
    ],
    group: 'required',
    order: 4,
  },

  // ===== 节点配置 =====
  {
    name: 'NODE_TYPE',
    title: '传输协议',
    description: '节点使用的代理协议类型',
    type: 'integer',
    required: false,
    defaultValue: 2,
    options: [
      { value: 1, label: 'Shadowsocks', description: '轻量级加密代理协议' },
      { value: 2, label: 'VLESS', description: '轻量级协议，无加密开销（推荐）' },
      { value: 3, label: 'VMess', description: 'V2Ray 原生协议，安全性高' },
      { value: 4, label: 'Hysteria', description: '基于 QUIC 的高速协议（v1）' },
      { value: 5, label: 'Hysteria2', description: '基于 QUIC 的高速协议（v2）' },
      { value: 6, label: 'Trojan', description: '伪装 HTTPS 流量' },
      { value: 7, label: 'TUIC', description: '基于 QUIC 的轻量协议' },
      { value: 8, label: 'AnyTLS', description: '通用 TLS 隧道' },
    ],
    group: 'node',
    order: 5,
  },
  {
    name: 'NODE_INOUT_TYPE',
    title: '节点模式',
    description: '节点的运行模式：独立、入站或出站',
    type: 'string',
    required: false,
    defaultValue: 'stand',
    options: [
      { value: 'stand', label: '独立节点', description: '独立运行的完整节点' },
      { value: 'in', label: '入站节点', description: '入站节点，需要配置出口服务器地址' },
      { value: 'out', label: '出站节点', description: '出站节点，作为入站节点的出口' },
    ],
    group: 'node',
    order: 6,
  },
  {
    name: 'NODE_OUT_SERVER',
    title: '出口节点地址',
    description: '当节点模式为"入站节点"时，指定出口节点的地址和端口',
    type: 'string',
    required: false,
    placeholder: 'out-node.example.com:443',
    pattern: '^[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]:\\d{1,5}$',
    dependsOn: { field: 'NODE_INOUT_TYPE', value: 'in' },
    group: 'node',
    order: 7,
  },

  // ===== 证书配置 =====
  {
    name: 'CERT_MODE',
    title: '证书模式',
    description: 'TLS 证书的获取方式',
    type: 'string',
    required: false,
    defaultValue: 'none',
    options: [
      { value: 'none', label: '无证书', description: '不使用 TLS 证书（仅限内网或测试）' },
      { value: 'http', label: 'HTTP 自动申请', description: '通过 HTTP-01 验证自动申请 Let\'s Encrypt 证书' },
      { value: 'dns', label: 'DNS 自动申请', description: '通过 DNS-01 验证自动申请证书（支持通配符）' },
      { value: 'self', label: '自签名证书', description: '生成自签名证书（客户端需信任）' },
    ],
    group: 'certificate',
    order: 8,
  },
  {
    name: 'CERT_DOMAIN',
    title: '证书域名',
    description: 'TLS 证书绑定的域名',
    type: 'string',
    required: false,
    defaultValue: 'example.com',
    placeholder: 'node.example.com',
    pattern: '^[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]$',
    dependsOn: { field: 'CERT_MODE', notValue: 'none' },
    group: 'certificate',
    order: 9,
  },

  // ===== 自动化选项 =====
  {
    name: 'IF_GENERATE',
    title: '自动生成配置',
    description: '是否自动生成节点配置文件',
    type: 'string',
    required: false,
    defaultValue: 'y',
    options: [
      { value: 'y', label: '是', description: '自动生成完整的配置文件（推荐）' },
      { value: 'n', label: '否', description: '使用已有配置文件或手动配置' },
    ],
    group: 'automation',
    order: 10,
  },
  {
    name: 'IF_REGISTER',
    title: '执行注册脚本',
    description: '安装完成后是否执行节点注册脚本（register.py）',
    type: 'string',
    required: false,
    defaultValue: 'n',
    options: [
      { value: 'y', label: '是', description: '自动下载并执行 register.py 注册节点（需要 Python）' },
      { value: 'n', label: '否', description: '跳过注册步骤' },
    ],
    group: 'automation',
    order: 11,
  },

  // ===== 高级配置 =====
  {
    name: 'NODE_TYPE2',
    title: 'Reality 配置',
    description: 'VLESS Reality 模式配置（仅当传输协议为 VLESS 时有效）',
    type: 'string',
    required: false,
    defaultValue: '',
    options: [
      { value: '', label: '标准模式', description: '使用标准 VLESS 协议' },
      { value: 'reality', label: 'Reality 模式', description: '使用 Reality 增强隐蔽性' },
    ],
    dependsOn: { field: 'NODE_TYPE', value: 2 },
    group: 'advanced',
    order: 12,
  },
  {
    name: 'UUID_AB',
    title: 'Reality UUID',
    description: 'Reality 模式的用户 UUID',
    type: 'string',
    required: false,
    placeholder: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
    pattern: '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    dependsOn: { field: 'NODE_TYPE2', value: 'reality' },
    group: 'advanced',
    order: 13,
  },
  {
    name: 'SHORT_ID',
    title: 'Reality Short ID',
    description: 'Reality 模式的 Short ID',
    type: 'string',
    required: false,
    placeholder: 'xxxxxxxxxxxx',
    pattern: '^[0-9a-fA-F]{1,16}$',
    dependsOn: { field: 'NODE_TYPE2', value: 'reality' },
    group: 'advanced',
    order: 14,
  },
  {
    name: 'REALITY_SERVER_NAME',
    title: 'Reality 握手域名',
    description: 'Reality 模式伪装的目标服务器域名',
    type: 'string',
    required: false,
    defaultValue: 'www.apple.com',
    placeholder: 'www.apple.com',
    dependsOn: { field: 'NODE_TYPE2', value: 'reality' },
    group: 'advanced',
    order: 15,
  },

  // ===== GitHub 配置 =====
  {
    name: 'GITHUB_TOKEN',
    title: 'GitHub Token',
    description: 'GitHub 访问令牌，用于提高 API 速率限制和加速下载',
    type: 'string',
    required: false,
    placeholder: 'ghp_xxxxxxxxxxxxxxxxxxxx',
    pattern: '^ghp_[a-zA-Z0-9]{36}$',
    sensitive: true,
    group: 'github',
    order: 16,
  },
  {
    name: 'RELEASE_REPO',
    title: 'Release 仓库',
    description: 'ad2nx 发行版的 GitHub 仓库地址',
    type: 'string',
    required: false,
    defaultValue: 'Lawer09/ad2nx',
    placeholder: 'owner/repo',
    pattern: '^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$',
    group: 'github',
    order: 17,
  },
  {
    name: 'SCRIPT_REPO',
    title: '脚本仓库',
    description: '安装脚本的 GitHub 仓库地址',
    type: 'string',
    required: false,
    defaultValue: 'Lawer09/ad2nx-s',
    placeholder: 'owner/repo',
    pattern: '^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$',
    group: 'github',
    order: 18,
  },
  {
    name: 'SCRIPT_BRANCH',
    title: '脚本分支',
    description: '安装脚本的 Git 分支名称',
    type: 'string',
    required: false,
    defaultValue: 'master',
    placeholder: 'master',
    group: 'github',
    order: 19,
  },
];

// ==================== 工具函数 ====================

/**
 * 获取字段的默认值
 */
export function getDefaultConfig(): Partial<EnvConfig> {
  const defaults: Partial<EnvConfig> = {};
  for (const field of formFields) {
    if (field.defaultValue !== undefined) {
      (defaults as any)[field.name] = field.defaultValue;
    }
  }
  return defaults;
}

/**
 * 验证配置是否完整
 */
export function validateConfig(config: Partial<EnvConfig>): { valid: boolean; errors: string[] } {
  const errors: string[] = [];
  
  for (const field of formFields) {
    const value = (config as any)[field.name];
    
    // 检查必填
    if (field.required && (value === undefined || value === null || value === '')) {
      errors.push(`${field.title} 是必填项`);
      continue;
    }
    
    // 跳过空值的非必填字段
    if (value === undefined || value === null || value === '') {
      continue;
    }
    
    // 检查正则
    if (field.pattern && typeof value === 'string') {
      const regex = new RegExp(field.pattern);
      if (!regex.test(value)) {
        errors.push(`${field.title} 格式不正确`);
      }
    }
    
    // 检查数字范围
    if (field.type === 'integer' && typeof value === 'number') {
      if (field.min !== undefined && value < field.min) {
        errors.push(`${field.title} 不能小于 ${field.min}`);
      }
      if (field.max !== undefined && value > field.max) {
        errors.push(`${field.title} 不能大于 ${field.max}`);
      }
    }
    
    // 检查字符串长度
    if (field.type === 'string' && typeof value === 'string') {
      if (field.min !== undefined && value.length < field.min) {
        errors.push(`${field.title} 长度不能少于 ${field.min} 个字符`);
      }
      if (field.max !== undefined && value.length > field.max) {
        errors.push(`${field.title} 长度不能超过 ${field.max} 个字符`);
      }
    }
  }
  
  return { valid: errors.length === 0, errors };
}

/**
 * 将配置转换为环境变量格式
 */
export function configToEnvString(config: Partial<EnvConfig>): string {
  const lines: string[] = [];
  
  for (const field of formFields) {
    const value = (config as any)[field.name];
    if (value !== undefined && value !== null && value !== '') {
      lines.push(`export ${field.name}="${value}"`);
    }
  }
  
  return lines.join('\n');
}

/**
 * 将配置转换为 .env 文件格式
 */
export function configToDotEnv(config: Partial<EnvConfig>): string {
  const lines: string[] = [];
  
  for (const field of formFields) {
    const value = (config as any)[field.name];
    if (value !== undefined && value !== null && value !== '') {
      lines.push(`${field.name}="${value}"`);
    }
  }
  
  return lines.join('\n');
}

/**
 * 检查字段是否应该显示（基于依赖条件）
 */
export function shouldShowField(field: FormField, config: Partial<EnvConfig>): boolean {
  if (!field.dependsOn) {
    return true;
  }
  
  const dependValue = (config as any)[field.dependsOn.field];
  
  if (field.dependsOn.value !== undefined) {
    return dependValue === field.dependsOn.value;
  }
  
  if (field.dependsOn.notValue !== undefined) {
    return dependValue !== field.dependsOn.notValue;
  }
  
  return true;
}
