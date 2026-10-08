class MessagesController < ApplicationController
  SYSTEM_PROMPT = "You are a Teaching Assistant.\n\nI am a student at the Le Wagon Web Development Bootcamp, learning how to code.\n\nHelp me break down my problem into small, actionable steps, without giving away solutions.\n\n
  You have access to tools:
  - Search for challenges in our database when a student asks about a topic.
  - Check teacher availability when a student needs help from a person.
  - Create a help ticket with a single available teacher when a student asks for help. Do not create multiple tickets.
  \n\nAnswer concisely in Markdown."
  BATCH_NUMBER = 2360

  def create
    @chat = current_user.chats.find(params[:chat_id])
    @challenge = @chat.challenge
    @message = Message.new(message_params)
    @message.chat = @chat
    @message.role = "user"

    if @message.save
      @assistant_message = Message.create(role: "assistant", content: "", chat: @chat)

      response = ask_llm

      @assistant_message = @assistant_message.update(content: response.content)
      # broadcast_replace(@assistant_message) MY BAD I HAD IT DOUBLE !!
      @chat.generate_title_from_first_message

      respond_to do |format|
        format.turbo_stream # renders `app/views/messages/create.turbo_stream.erb`
        format.html { redirect_to chat_path(@chat) }
      end
    else
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.update("new_message_container", partial: "messages/form", locals: { chat: @chat, message: @message }) }
        format.html { render "chats/show", status: :unprocessable_entity }
      end
    end
  end

  private

  def broadcast_replace(assistant_message)
    Turbo::StreamsChannel.broadcast_replace_to(
      @chat,
      target: helpers.dom_id(assistant_message),
      partial: "messages/message",
      locals: { message: assistant_message }
    )
  end

  def ask_llm
    @ruby_llm_chat = RubyLLM.chat
    build_conversation_history

    @ruby_llm_chat.with_tool(SearchChallengesTool) # added this
    @ruby_llm_chat.with_tool(AvailableTeachersTool.new(batch_number: BATCH_NUMBER)) # we pass an instance of the tool, because we need to pass the batch number
    @ruby_llm_chat.with_tool(CreateHelpTicketTool.new(user: current_user))

    @ruby_llm_chat.with_instructions(instructions)
    @ruby_llm_chat.ask(@message.content)do |chunk|
      next if chunk.content.blank? # skip empty chunks

      @assistant_message.content += chunk.content
      broadcast_replace(@assistant_message)
    end
  end

  def build_conversation_history
    @chat.messages.each do |message|
      next if message.content.blank? # adding to skip empty messages
        @ruby_llm_chat.add_message(message)

    end
  end

  def challenge_context
    "Here is the context of the challenge: #{@challenge.content}."
  end

  def instructions
    [SYSTEM_PROMPT, challenge_context, @challenge.system_prompt].compact.join("\n\n")
  end

  def message_params
    params.require(:message).permit(:content)
  end
end
