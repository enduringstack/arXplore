export interface Author {
  name: string;
  affiliation: string;
}

export interface Paper {
  id: string;
  title: string;
  summary: string;
  authors: Author[];
  published: string;
  updated: string;
  pdfUrl: string;
  htmlUrl: string;
  categories: string[];
  tldr?: string;  // 一句话TLDR摘要
}

export interface Category {
  id: string;
  name: string;
  query: string;
  isDefault: boolean;
}

// 阅读计划
export const PLAN_UNREAD = 0;
export const PLAN_READING = 1;
export const PLAN_DONE = 2;

export interface ReadingPlan {
  paperId: string;
  status: number;       // 0=未读, 1=在读, 2=已读
  priority: number;     // 0=普通, 1=重要, 2=紧急
  deadline: string;     // 计划日期 yyyy-MM-dd
  notes: string;        // 读后感
  startedAt: string;    // 开始时间
  completedAt: string;  // 完成时间
}

export function getDefaultCategories(): Category[] {
  return [
    { id: 'edge_llm', name: '端侧大模型', query: 'all:"on-device" AND all:"language model"', isDefault: true },
    { id: 'agent', name: 'Agent', query: 'ti:agent AND abs:"large language model"', isDefault: true },
    { id: 'compression', name: '模型轻量化', query: 'all:quantization OR all:pruning OR all:"knowledge distillation"', isDefault: true },
    { id: '3dgs', name: '3DGS', query: 'all:"gaussian splatting"', isDefault: true },
    { id: 'world_model', name: '世界模型', query: 'ti:"world model"', isDefault: true },
    { id: 'deployment', name: '模型部署', query: 'all:"model deployment" OR all:"model inference" OR all:"model serving"', isDefault: true },
    { id: 'operator', name: '算子优化', query: 'all:"operator optimization" OR all:"kernel optimization" OR all:"CUDA optimization"', isDefault: true },
    { id: 'ai_dev', name: 'AI辅助研发', query: 'all:"code generation" AND all:"language model"', isDefault: true },
    { id: 'vla', name: '具身智能VLA', query: 'all:"vision language action" OR all:"embodied intelligence"', isDefault: true },
    { id: 'ai_infra', name: 'AI Infra', query: 'all:"AI infrastructure" OR all:"training infrastructure" OR all:"GPU cluster" OR all:"distributed training"', isDefault: true },
    { id: 'model_compute', name: '模型计算/算子', query: 'all:"custom operator" OR all:"tensor computation" OR all:"compute kernel" OR all:"FlashAttention"', isDefault: true },
    { id: 'rl', name: '强化学习', query: 'ti:"reinforcement learning" OR ti:RLHF OR ti:PPO OR ti:GRPO', isDefault: true },
  ];
}
