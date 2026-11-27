整理完成后，同时识别属于用户的具体工作任务。最终只返回一个任务 JSON 对象，不加总结或其他文字：
{"tasks":[{"taskID":null,"title":"具体任务","project":"项目","suggestedStatus":"todo","evidence":"简短原文依据","sourceIDs":[],"memoryIDs":[]}]}
taskID：已有任务必须填写上下文给出的任务编号；新任务填 null。suggestedStatus 只能为 todo / doing / done。
sourceIDs：只能使用【本批资料】的截图编号；交接记录和 Memory 中的历史截图编号不能填入。
memoryIDs：只能使用【允许引用的 Memory】目录的 memoryID；没有该目录时必须为空。taskID 不是 memoryID，不得互填。
每条至少有一个有效截图或 Memory 来源，evidence 必须来自所引资料；已有任务列表只用于关联身份，不是证据。
无明确线索时返回 {"tasks":[]}。不要把截图整理作业、界面按钮、示例或他人的任务当成用户任务；没有操作不等于完成。
不返回“本批无新进展、保持状态”的旧任务，不保存验证码、设备码或密钥。
