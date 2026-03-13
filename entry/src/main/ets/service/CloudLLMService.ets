import { http } from '@kit.NetworkKit';
import { SILICONFLOW_API_KEY } from '../config/ApiKeys';

const API_URL = 'https://api.siliconflow.cn/v1/chat/completions';
const API_KEY = SILICONFLOW_API_KEY;
const MODEL = 'Qwen/Qwen2.5-7B-Instruct';

interface ResMessage {
  content: string;
}

interface ResChoice {
  message: ResMessage;
}

interface ApiResponse {
  choices: ResChoice[];
}

interface ReqMessage {
  role: string;
  content: string;
}

interface ReqBody {
  model: string;
  messages: ReqMessage[];
  max_tokens: number;
  temperature: number;
}

export class CloudLLMService {
  static async generateTLDR(title: string, abstract: string): Promise<string> {
    const prompt = `请用一句简洁的中文概括这篇论文的核心贡献（不超过50个字）：\n\n标题：${title}\n\n摘要：${abstract.substring(0, 500)}`;
    return await CloudLLMService.chat(prompt);
  }

  static async translate(text: string): Promise<string> {
    const prompt = `请将以下学术论文的英文内容翻译为流畅的中文，保留专业术语的英文原文（用括号标注）：\n\n${text.substring(0, 2000)}`;
    return await CloudLLMService.chat(prompt);
  }

  static async chat(prompt: string): Promise<string> {
    const req = http.createHttp();
    try {
      const msg: ReqMessage = { role: 'user', content: prompt };
      const body: ReqBody = { model: MODEL, messages: [msg], max_tokens: 2048, temperature: 0.7 };
      const resp = await req.request(API_URL, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${API_KEY}`
        },
        extraData: JSON.stringify(body),
        connectTimeout: 30000,
        readTimeout: 60000,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode === 200) {
        const data = JSON.parse(resp.result as string) as ApiResponse;
        if (data.choices && data.choices.length > 0) {
          return data.choices[0].message.content;
        }
        return '生成失败：无返回内容';
      }
      return `请求失败: HTTP ${resp.responseCode}`;
    } catch (_) {
      return '云端 AI 请求失败，请检查网络';
    } finally {
      req.destroy();
    }
  }
}
