%    -*- Erlang -*- 
%    File:	mail.erl  (~jb/mail.erl)
%    Author:	Johan Bevemyr
%    Created:	Sat Oct 25 10:59:24 2003
%    Purpose:   

-module('mail').
-author('jb@trut.bluetail.com').

-export([parse_headers/1, list/1, list/3, ploop/5,pop_request/4, diff/2,
	 session_manager_init/0, check_cookie/1, check_session/1, 
	 login/2, display_login/2, stat/3, showmail/2, compose/1, compose/7,
	 send/6, get_val/3, logout/1, base64_2_str/1, retr/4, 
	 showheaders/2, delete/2]).

-include("../../../include/yaws_api.hrl").
-include("defs.hrl").

-record(info,
	{
	  nr,
	  size,
	  headers
	 }).

-record(mhead,
	{
	  from="",
	  to="",
	  cc="",
	  bcc="",
	  subject="",
	  date="",
	  content_type,
	  transfer_encoding,
	  other = []
	 }).

-record(pstate,
	{
	  port,
	  user,
	  pass,
	  cmd,
	  acc = [],
	  from,
	  lines,
	  reply=[],
	  more=true,
	  remain
	 }).

-record(session,
	{
	  user,
	  passwd,
	  cookie
	 }).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%

build_toolbar(Entries) ->
    {table, [{bgcolor,"c0c0c0"},{cellpadding,0},{cellspacing,0},{border,0}],
     [{tr,[],{td, [{colspan,20},{height,1},{bgcolor,white}],
	      {img, [{src,"spacer.gif"}, {width,1},{height,1},
		     {alt,""}, {border,0}],[]}}},
      {tr,[], build_toolbar(Entries, -1)},
      {tr,[],{td, [{colspan,20},{height,1},{bgcolor,gray}],
	      {img, [{src,"spacer.gif"}, {width,1},{height,1},
		     {alt,""}, {border,0}],[]}}},
      {tr,[],{td, [{colspan,20},{height,1}],
	      {img, [{src,"spacer.gif"}, {width,1},{height,1},
		     {alt,""}, {border,0}],[]}}}]}.

build_toolbar([], Used) ->
    Percent = integer_to_list(100-Used)++"%",
    [{td, [nowrap,{width,Percent},{valign,middle},{align,left}],[]}];
build_toolbar([{[],Url,Cmd}|Rest], Used) ->
    if Used == -1 ->
	    [];
       true ->
	    [{td, [nowrap,{width,"1%"},{valign,middle},{align,left}],
	      {img, [{src,"tool-div.gif"},{width,2},{height,16},
		     {alt,""},{border,0},{hspace,2}]}}]
    end ++
	[{td, [nowrap,{width,"2%"},{valign,middle},{align,left}],
	  [{a, [{class,nolink}, {href,Url}],
	    {font, [{size,2},{color,"#000000"},{title,Cmd}], Cmd}}]} |
	 build_toolbar(Rest, Used+3)];    
build_toolbar([{Gif,Url,Cmd}|Rest], Used) ->
    if Used == -1 ->
	    [];
       true ->
	    [{td, [nowrap,{width,"1%"},{valign,middle},{align,left}],
	      {img, [{src,"tool-div.gif"},{width,2},{height,16},
		     {alt,""},{border,0},{hspace,2}]}}]
    end ++
    [{td, [nowrap,{width,"2%"},{valign,middle},{align,left}],
      {a, [{class,nolink},
	   {href,Url}],
       [{img, [{src,Gif},{vspace,2},{width,20},
	       {height,20},{alt,Cmd},{border,0}],[]}]}

     },
     {td, [nowrap,{width,"2%"},{valign,middle},{align,left}],
      [{a, [{class,nolink},
	    {href,Url}],
	{font, [{size,2},{color,"#000000"},{title,Cmd}], Cmd}}]} |
     build_toolbar(Rest, Used+4)].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%

delete(Session, ToDelete) ->
    tick_session(Session#session.cookie),
    Req = [del(M) || M <- ToDelete],
    pop_request(Req++[{"QUIT",sl}], ?POPSERVER,
		Session#session.user, Session#session.passwd),
    {redirect_local, {rel_path, "mail.yaws"}}.

send(Session, To, Cc, Bcc, Subject, Msg) ->
    tick_session(Session#session.cookie),
    RTo = string:tokens(To,","),
    RCc = string:tokens(Cc,","),
    RBcc = string:tokens(Bcc,","),
    Recipients = RTo ++ RCc ++ RBcc,
    Date = yaws:date_and_time_to_string(yaws:date_and_time()),
    Headers =
	(mail_header("To: ", To) ++
	 mail_header("From: ", Session#session.user++"@"++?MAILDOMAIN) ++
	 mail_header("Cc: ", Cc) ++
	 mail_header("Bcc: ", Bcc) ++
	 mail_header("Subject: ", Subject)),
    Message = io_lib:format("~sDate: ~s\r\n\r\n~s\r\n.\r\n",
			    [Headers, Date, Msg]),
    case smtp_send(?SMTPSERVER, Session, Recipients, Message) of
	ok ->
	    {redirect_local, {rel_path,"mail.yaws"}};
	{error, Reason} ->
	    (dynamic_headers() ++
	     compose(Session, Reason, To, Cc, Bcc, Subject, Msg))
    end.

mail_header(_Key, []) -> [];
mail_header(Key, Val) -> Key++Val++"\r\n".

compose(Session) ->
    compose(Session, "","","","","","").

compose(Session, Reason, To, Cc, Bcc, Subject, Msg) ->
    tick_session(Session#session.cookie),
    (dynamic_headers()++
     [{ehtml,
       [{script,[],
	 "function setCmd(val) { \n"
	 "   if (document.compose.to.value.length == 0) {\n"
	 "       alert('The To: field must not be empty.');\n"
	 "       document.compose.to.focus();\n"
	 "       return;\n"
	 "   }\n"
	 "   if (document.compose.text.value.length == 0) {\n"
	 "       alert('The message field must not be empty.');\n"
	 "       document.compose.text.focus();\n"
	 "       return;\n"
	 "   }\n"
	 "   document.compose.cmd.value=val;\n"
	 "   document.compose.submit();\n"
	 "}"
	},
	{style, [{type,"text/css"}],
	 "A:link    { color: 0;text-decoration: none}\n"
	 "A:visited { color: 0;text-decoration: none}\n"
	 "A:active  { color: 0;text-decoration: none}\n"},
	{body,[{bgcolor,silver},{marginheight,0},{link,"#000000"},
	       {topmargin,0},{leftmargin,0},{rightmargin,0},
	       {marginwidth,0}],
	 [{form, [{name,compose},{action,"send.yaws"},{method,post}],
	   [{table, [{border,0},{bgcolor,"c0c0c0"},{cellspacing,0},
		     {width,"100%"}],
	     {tr,[],{td,[{nowrap,true},{align,left},{valign,middle}],
		     {font, [{size,6},{color,black}],
		      "WebMail at "++?MAILDOMAIN}}}},
	    build_toolbar([{"tool-send.gif",
			    "javascript:setCmd('send');","Send"},
			   {"", "mail.yaws", "Close"}]),
	    {table, [{width,645},{border,0},{bgcolor,silver},{cellspacing,0},
		     {cellpadding,0}],
	     if
		 Reason == [] -> [];
		 true ->
		     [
		      {tr,[],[{td,[{colspan,2},{height,35},{align,left},
				   {valign,top}],
			       {font,[{color,red},{size,2},nowrap],
				["Error: ",Reason]}}]}
		     ]
	     end ++
	     [{tr,[],[{td,[{height,0},{align,left},{valign,top}],[]},
		      {td,[{height,0},{align,left},{valign,top}],[]}]},
	      {tr,[],[{td,[{height,35},{align,left},{valign,top}],
		       {font,[{color,"#000000"},{size,2},nowrap],
			{pre_html,"&nbsp;To:&nbsp;"}}},
		      {td,[{height,35},{align,left},{valign,top}],
		       {input,[{name,to},{type,text},{size,66},{value,To}]}}]},
	      {tr,[],[{td,[{height,0},{align,left},{valign,top}],[]},
		      {td,[{height,0},{align,left},{valign,top}],[]}]},
	      {tr,[],[{td,[{height,35},{align,left},{valign,top}],
		       {font,[{color,"#000000"},{size,2},nowrap],
			{pre_html,"&nbsp;Cc:&nbsp;"}}},
		      {td,[{height,35},{align,left},{valign,top}],
		       {input,[{name,cc},{type,text},{size,66},{value,Cc}]}}]},
	      {tr,[],[{td,[{height,0},{align,left},{valign,top}],[]},
		      {td,[{height,0},{align,left},{valign,top}],[]}]},
	      {tr,[],[{td,[{height,35},{align,left},{valign,top}],
		       {font,[{color,"#000000"},{size,2},nowrap],
			{pre_html,"&nbsp;Bcc:&nbsp;"}}},
		      {td,[{height,35},{align,left},{valign,top}],
		       {input,[{name,bcc},{type,text},{size,66},{value,Bcc}]}}
		     ]},
	      {tr,[],[{td,[{height,35},{align,left},{valign,top},nowrap],
		       {font,[{color,"#000000"},{size,2}],
			{pre_html,"&nbsp;Subject:&nbsp;"}}},
		      {td,[{colspan,3},{align,left},{valign,top}],
		       {input,[{name,subject},{type,text},{size,66},
			       {value,Subject}]}}]}
	     ]
	    },
	    {table, [{bgcolor,silver},{border,0},{cellspacing,0},
		     {cellpadding,0}],
	     {tr,[],
	      {td,[{align,left},{valign,top}],
	       {textarea, [{wrap,virtual},{name,text},{cols,78},{rows,21}],
	       Msg}}
	     }
	    },
	    {input,[{type,hidden},{name,cmd},{value,""}],[]}
	   ]
	  }
	 ]
	}
       ]
      }]).


showmail(Session, MailNr) ->
    tick_session(Session#session.cookie),
    {H,Msg} = retr(?POPSERVER, Session#session.user,
		   Session#session.passwd, MailNr),

    ContentType = 
	if 
	    H#mhead.content_type == undefined -> undefined;
	    true -> element(1,H#mhead.content_type)
	end,

    (dynamic_headers() ++
     [{ehtml,
       [{script,[],
	 "function setCmd(val) { \n"
	 "   document.compose.cmd.value=val;\n"
	 "   document.compose.submit();\n"
	 "}"
	},
	{style, [{type,"text/css"}],
	 "A:link    { color: 0;text-decoration: none}\n"
	 "A:visited { color: 0;text-decoration: none}\n"
	 "A:active  { color: 0;text-decoration: none}\n"},
	{body,[{bgcolor,silver},{marginheight,0},{topmargin,0},{leftmargin,0},
	       {rightmargin,0},{marginwidth,0}],
	 {form, [{name,compose},{action,"reply.yaws"},{method,post}],
	  [{table, [{border,0},{bgcolor,"c0c0c0"},{cellspacing,0},
		    {width,"100%"}],
	    {tr,[],{td,[{nowrap,true},{align,left},{valign,middle}],
		    {font, [{size,6},{color,black}],
		     "WebMail at "++?MAILDOMAIN}}}},
	   build_toolbar([{"tool-newmail.gif", "javascript:setCmd('send');",
			   "Reply"},
			  {"","headers.yaws?nr="++integer_to_list(MailNr),
			   "Headers"},
			  {"","mail.yaws","Close"}]),
	   {table,[{width,645},{height,"100%"},{border,0},{bgcolor,silver},
		   {cellspacing,0},{callpadding,0}],
	    {tr,[],{td,[{valign,top},{height,"1%"}],
		    [{table,
		      [{border,0},{cellspacing,0},{cellpadding,0},{width,"100%"},
		       {bgcolor,silver}],
		      [{tr,[],
			[{td,[{valign,middle},{align,left},{width,"15%"},
			      {height,25}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;From:&nbsp;"}}}},
			 {td, [{valign,middle},{align,left}],
			  {font, [{color,"#000000"},{size,2}],
			   [{pre_html,"&nbsp;"},
			    unquote(decode(H#mhead.from))]}},
			 {td,[{valign,middle},{align,right},{height,"25"}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;Sent:&nbsp;"}}}},
			 {td, [nowrap,{valign,middle},{align,right},
			       {width,"30%"}],
			  {font, [{color,"#000000"},{size,2}],
			   {pre_html,"&nbsp;"++H#mhead.date}}}]},
		       {tr,[],
			[{td,[{valign,top},{align,left},{width,"15%"},
			      {height,25}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;To:&nbsp;"}}}},
			 {td, [{valign,top},{align,left},{width,"100%"}],
			  {font, [{color,"#000000"},{size,2}],
			   [{pre_html,"&nbsp;"},
			    unquote(decode(H#mhead.to))]}}]},
		       {tr,[],
			[{td,[{valign,middle},{align,left},{width,"15%"},
			      {height,25}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;Cc:&nbsp;"}}}},
			 {td, [{valign,middle},{align,left},{width,"100%"}],
			  {font, [{color,"#000000"},{size,2}],
			   [{pre_html,"&nbsp;"},H#mhead.cc]}}]},
		       {tr,[],
			[{td,[{valign,middle},{align,left},{width,"15%"},
			      {height,25}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;Subject:&nbsp;"}}}},
			 {td, [{valign,middle},{align,left},{width,"100%"}],
			  {font, [{color,"#000000"},{size,2}],
			   [{pre_html,"&nbsp;"},decode(H#mhead.subject)]}}]}
		      ]},
		     {table, [{width,"100%"},{border,1},{cellpadding,6},
			      {class,msgbody}],
		      {tr,[],
		       {td,[{width,"100%"},{height,300},{valign,top},
			    {bgcolor,white}],
			{p,[],{font,[{size,3}], 
			       if ContentType == "text/html" ->
				       {pre_html,Msg};
				  true ->
				       {pre,[],Msg}
			       end
			      }}}
		      }
		     }
		    ]
		   }
	    }
	   },
	   {input,[{type,hidden},{name,from},
		   {value,retr_from(H#mhead.from)}],[]},
	   {input,[{type,hidden},{name,to},
		   {value,retr_from(H#mhead.to)}],[]},
	   {input,[{type,hidden},{name,cc},
		   {value,retr_from(H#mhead.cc)}],[]},
	   {input,[{type,hidden},{name,bcc},
		   {value,retr_from(H#mhead.bcc)}],[]},
	   {input,[{type,hidden},{name,subject},{value,H#mhead.subject}],[]},
	   {input,[{type,hidden},{name,cmd},{value,""}],[]}
	  ]
	 }
	}
       ]}]).

showheaders(Session, MailNr) ->
    tick_session(Session#session.cookie),
    {H,Msg} = rtop(?POPSERVER, Session#session.user,
		   Session#session.passwd, MailNr),

    ContentType = undefined,

    (dynamic_headers() ++
     [{ehtml,
       [{script,[],
	 "function setCmd(val) { \n"
	 "   document.compose.cmd.value=val;\n"
	 "   document.compose.submit();\n"
	 "}"
	},
	{style, [{type,"text/css"}],
	 "A:link    { color: 0;text-decoration: none}\n"
	 "A:visited { color: 0;text-decoration: none}\n"
	 "A:active  { color: 0;text-decoration: none}\n"},
	{body,[{bgcolor,silver},{marginheight,0},{topmargin,0},{leftmargin,0},
	       {rightmargin,0},{marginwidth,0}],
	 {form, [{name,compose},{action,"reply.yaws"},{method,post}],
	  [{table, [{border,0},{bgcolor,"c0c0c0"},{cellspacing,0},
		    {width,"100%"}],
	    {tr,[],{td,[{nowrap,true},{align,left},{valign,middle}],
		    {font, [{size,6},{color,black}],
		     "WebMail at "++?MAILDOMAIN}}}},
	   build_toolbar([{"tool-newmail.gif", "javascript:setCmd('send');",
			   "Reply"},
			  {"","showmail.yaws?nr="++integer_to_list(MailNr),
			   "Message"},
			  {"","mail.yaws","Close"}]),
	   {table,[{width,645},{height,"100%"},{border,0},{bgcolor,silver},
		   {cellspacing,0},{callpadding,0}],
	    {tr,[],{td,[{valign,top},{height,"1%"}],
		    [{table,
		      [{border,0},{cellspacing,0},{cellpadding,0},{width,"100%"},
		       {bgcolor,silver}],
		      [{tr,[],
			[{td,[{valign,middle},{align,left},{width,"15%"},
			      {height,25}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;From:&nbsp;"}}}},
			 {td, [{valign,middle},{align,left}],
			  {font, [{color,"#000000"},{size,2}],
			   [{pre_html,"&nbsp;"},
			    unquote(decode(H#mhead.from))]}},
			 {td,[{valign,middle},{align,right},{height,"25"}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;Sent:&nbsp;"}}}},
			 {td, [nowrap,{valign,middle},{align,right},
			       {width,"30%"}],
			  {font, [{color,"#000000"},{size,2}],
			   {pre_html,"&nbsp;"++H#mhead.date}}}]},
		       {tr,[],
			[{td,[{valign,top},{align,left},{width,"15%"},
			      {height,25}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;To:&nbsp;"}}}},
			 {td, [{valign,top},{align,left},{width,"100%"}],
			  {font, [{color,"#000000"},{size,2}],
			   [{pre_html,"&nbsp;"},
			    unquote(decode(H#mhead.to))]}}]},
		       {tr,[],
			[{td,[{valign,middle},{align,left},{width,"15%"},
			      {height,25}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;Cc:&nbsp;"}}}},
			 {td, [{valign,middle},{align,left},{width,"100%"}],
			  {font, [{color,"#000000"},{size,2}],
			   [{pre_html,"&nbsp;"},H#mhead.cc]}}]},
		       {tr,[],
			[{td,[{valign,middle},{align,left},{width,"15%"},
			      {height,25}],
			  {font, [{color,"#000000"},{size,2}],
			   {nobr,[],{pre_html,"&nbsp;Subject:&nbsp;"}}}},
			 {td, [{valign,middle},{align,left},{width,"100%"}],
			  {font, [{color,"#000000"},{size,2}],
			   [{pre_html,"&nbsp;"},decode(H#mhead.subject)]}}]}
		      ]},
		     {table, [{width,"100%"},{border,1},{cellpadding,6},
			      {class,msgbody}],
		      {tr,[],
		       {td,[{width,"100%"},{height,300},{valign,top},
			    {bgcolor,white}],
			{p,[],{font,[{size,3}], 
			       if ContentType == "text/html" ->
				       {pre_html,Msg};
				  true ->
				       {pre,[],Msg}
			       end
			      }}}
		      }
		     }
		    ]
		   }
	    }
	   },
	   {input,[{type,hidden},{name,from},
		   {value,retr_from(H#mhead.from)}],[]},
	   {input,[{type,hidden},{name,to},
		   {value,retr_from(H#mhead.to)}],[]},
	   {input,[{type,hidden},{name,cc},
		   {value,retr_from(H#mhead.cc)}],[]},
	   {input,[{type,hidden},{name,bcc},
		   {value,retr_from(H#mhead.bcc)}],[]},
	   {input,[{type,hidden},{name,subject},{value,H#mhead.subject}],[]},
	   {input,[{type,hidden},{name,cmd},{value,""}],[]}
	  ]
	 }
	}
       ]}]).

list(Session) ->
    tick_session(Session#session.cookie),
    H = list(?POPSERVER, Session#session.user, Session#session.passwd),
    (dynamic_headers()++
     [{ehtml,
       [{script,[],
	 "function setCmd(val) { \n"
	 "   if (val == 'delete') {\n"
	 "      var res = confirm('Are you sure you want to delete the selected emails?');\n" 
	 "      if (res) { \n"
	 "           document.list.cmd.value=val;\n"
	 "           document.list.submit();\n"
	 "      } else { \n"
	 "           return;\n"
	 "      }\n"
	 "   }\n"
	 "   document.list.cmd.value=val;\n"
	 "   document.list.submit();\n"
	 "}"
	},
	{style,[{type,"text/css"}],
	 "A:link    { color: black; text-decoration: none}\n"
	 "A:visited { color: black; text-decoration: none}\n"
	 "A:active  { color: black; text-decoration: none}\n"
	 ".AList    { color: black; text-decoration: none}\n"
	 ".Head     { border-right:1px solid white}"},
	{form, [{name,list},{action,"listop.yaws"},{method,post}],
	 [{table, [{border,0},{bgcolor,"c0c0c0"},
		   {cellspacing,0},{width,"100%"}],
	   {tr,[],{td,[{nowrap,true},{align,left},{valign,middle}],
		   {font, [{size,6},{color,black}],
		    "WebMail at "++?MAILDOMAIN}}}},
	  build_toolbar([{"tool-newmail.gif","compose.yaws","New Message"},
			 {"tool-delete.gif","javascript:setCmd('delete')",
			  "Delete"},
			 {"","logout.yaws","Logout"}]),
	  {table, [{border,0},{bgcolor,"666666"},{cellspacing,0},
		   {width,"100%"}],
	   {tr,[],{td,[{nowrap,true},{align,left},{valign,middle}],
		   {font, [{size,2},{color,"#ffffff"}],
		    "Inbox for "++Session#session.user}}}},
	  {table, [{border,0},{cellspacing,0},{cellpadding,1},{width,"100%"}],
	   [{tr, [{bgcolor,"c0c0c0"},{valign,middle}],
	     [{th,[{class,head}],
	       {img,[{src,"view-mark.gif"},{width,13},{height,13}],[]}},
	      {th,[{align,left},{valign,middle},{class,head}],
	       {font,[{size,2},{color,black}],"From"}},
	      {th,[{align,left},{valign,middle},{class,head}],
	       {font,[{size,2},{color,black}],"Subject"}},
	      {th,[{align,left},{valign,middle},{class,head}],
	       {font,[{size,2},{color,black}],"Size"}}]}] ++
	   format_summary(H)},
	   {input,[{type,hidden},{name,cmd},{value,""}],[]}
	 ]}]}]).

format_summary(Hs) ->
    [format_summary_line(H) || H <- Hs].

format_summary_line(I) ->
    H = I#info.headers,
    {tr, [{align,center},{valign,top}],
     [{td, [{align,center},{valign,top},{class,"List"}],
       {input, [{type,checkbox},{name,I#info.nr},{value,yes}],[]}},
      {td, [{align,left},{valign,top},{class,"List"}],
       {a, [{href,"showmail.yaws?nr="++integer_to_list(I#info.nr)}],
	{font,[{size,2},{color,black}],{b,[],format_from(H#mhead.from)}}}},
      {td, [{align,left},{valign,top},{class,"List"}],
       {a, [{href,"showmail.yaws?nr="++integer_to_list(I#info.nr)}],
	{font,[{size,2},{color,black}],{b,[],decode(H#mhead.subject)}}}},
      {td, [{align,left},{valign,top},{class,"List"}],
       {a, [{href,"showmail.yaws?nr="++integer_to_list(I#info.nr)}],
	{font,[{size,2},{color,black}],{b,[],integer_to_list(I#info.size)}}}}
     ]}.

format_from(From) ->
    case string:chr(From,$<) of
	0 ->
	    From;
	N ->
	    NewF=string:strip(unquote(decode(string:substr(From,1,N-1)))),
	    if 
		NewF == [] -> From;
		true -> NewF
	    end
    end.

retr_from(FromStr) ->
    Op =
	fun(From) ->
		case {string:chr(From,$<),string:chr(From,$>)} of
		    {S,E} when S>0, E>0 ->
			string:substr(From,S,(E-S)+1);
		    _ ->
			From
		end
	end,
    FromList = string:tokens(FromStr, ","),
    Fs = [Op(F) || F <- FromList],
    format_list(Fs).

format_list([]) -> [];
format_list([E]) -> E;
format_list([E|Es]) ->
    E++","++format_list(Es).

decode([]) -> [];
decode([$=,$?|Rest]) ->
    decode_scan(Rest);
decode([C|Cs]) ->
    [C | decode(Cs)].
     
decode_scan([]) -> [];
decode_scan([$?,$b,$?|Rest]) ->
    decode_b64(Rest,[]);
decode_scan([$?,$B,$?|Rest]) ->
    decode_b64(Rest,[]);
decode_scan([$?,$q,$?|Rest]) ->
    decode_q(Rest,[]);
decode_scan([$?,$Q,$?|Rest]) ->
    decode_q(Rest,[]);
decode_scan([$?,_,$?|Rest]) ->
    decode(Rest);
decode_scan([_|Rest]) ->
    decode_scan(Rest).

decode_q([], Acc) ->
    lists:revers(Acc);
decode_q([$?,$=|Rest], Acc) ->
    [lists:reverse(Acc)|decode(Rest)];
decode_q([$=,H1,H2|Rest], Acc) ->
    decode_q(Rest, [yaws:hex_to_integer([H1,H2])|Acc]);
decode_q([C|Cs], Acc) ->
    decode_q(Cs, [C|Acc]).

decode_b64([],Acc) ->
    Str = lists:reverse(Acc),
    case catch base64_2_str(Str) of
	{'EXIT',_} -> Str;
	Dec -> Dec
    end;
decode_b64([$?,$=|Rest],Acc) ->
    Str = lists:reverse(Acc),
    case catch base64_2_str(Str) of
	{'EXIT',_} -> [Str|decode(Rest)];
	Dec -> [Dec|decode(Rest)]
    end;
decode_b64([C|Rest], Acc) ->
    decode_b64(Rest,[C|Acc]).
	    

unquote([]) -> [];
unquote([$"|R]) -> unquote(R);
unquote([C|R]) -> [C|unquote(R)].

display_login(A, Status) ->
    (dynamic_headers() ++
     [{ehtml,
       [{body, [{onload,"document.f.user.focus();"}],
	 [{table, [{border,0},{bgcolor,"c0c0c0"},{cellspacing,0},
		   {width,"100%"}],
	   {tr,[],{td,[{nowrap,true},{align,left},{valign,middle}],
		   {font, [{size,6},{color,black}],
		    "WebMail at "++?MAILDOMAIN}}}},
	  {pre_html, io_lib:format("<p>Your login status is: ~s</p>",
				   [Status])},
	  {form,
	   [{method,post},
	    {name,f},
	    {action, "login.yaws"},
	    {autocomplete,"off"}],
	   {table,[{cellspacing, "5"}],
	    [{tr, [],
	      [{td, [], {p, [], "Username:"}},
	       {td, [], {input, [{name, user},
				 {type, text},
				 {size, "20"}]}}
	      ]},
	     {tr, [],
	      [{td, [], {p, [], "Password:"}},
	       {td, [], {input, [{name, password},
				 {type, password},
				 {size, "20"}]}}]},
	     {tr, [],
	      {td, [{align, "right"}, {colspan, "2"}],
	       {input, [{type, submit},
			{value, "Login"}]}}}
	    ]}}]
	}]
      }]).

logout(Session) ->
    logout_cookie(Session#session.cookie),
    (dynamic_headers() ++
     [{redirect_local, {rel_path,"mail.yaws"}}]).

login(User, Password) ->
    case stat(?POPSERVER, strip(User), strip(Password)) of
	{ok, _} ->
	    {ok, new_session(User, Password)};
	{error, Reason} ->
	    {error, Reason}
    end.

check_session(A) ->
    H = A#arg.headers,
    case yaws_api:find_cookie_val("mailsession", H#headers.cookie) of
	[] ->
	    display_login(A, "not logged in");
	CVal ->
	    case mail:check_cookie(CVal) of
		error ->
		    display_login(A, "not logged in");
		Session ->
		    {ok, Session}
	    end
    end.

strip(Str) ->
    lists:filter(fun(C)->not(lists:member(C,"\r\n"))end,Str).

dynamic_headers() ->
    [yaws_api:set_content_type("text/html"),
     {header, {cache_control, "no-store"}},
     {header, "Expires: -1"}].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% session server
%

tick_session(Cookie) ->
    session_server(),
    mail_session_manager ! {tick_session, Cookie}.

new_session(User, Password) ->
    session_server(),
    mail_session_manager !
	{new_session, #session{user=User,passwd=Password}, self()},
    receive
	{session_manager, Cookie} ->
	    Cookie
    end.

check_cookie(Cookie) ->
    session_server(),
    mail_session_manager ! {get_session, Cookie, self()},
    receive
	{session_manager, {ok, Session}} ->
	    Session;
	{session_manager, error} ->
	    error
    end.

logout_cookie(Cookie) ->
    session_server(),
    mail_session_manager ! {del_session, Cookie}.
    
session_server() ->
    case whereis(mail_session_manager) of
	undefined ->
	    Pid = spawn(?MODULE, session_manager_init, []),
	    register(mail_session_manager, Pid);
	_ ->
	    done
    end.

session_manager_init() ->
    {X,Y,Z} = seed(),
    random:seed(X, Y, Z),
    session_manager([]).

session_manager(C) ->
    receive
	{get_session, Cookie, From} ->
	    case lists:keysearch(Cookie, 1, C) of
		{value, {_,Session,_}} ->
		    From ! {session_manager, {ok, Session}};
		false ->
		    From ! {session_manager, error}
	    end,
	    session_manager(C);
	{new_session, Session, From} ->
	    Cookie = integer_to_list(random:uniform(1 bsl 50)),
	    From ! {session_manager, Cookie},
	    session_manager([{Cookie, Session#session{cookie=Cookie},
			      now()}|C]);
	{tick_session, Cookie} ->
	    case lists:keysearch(Cookie, 1, C) of
		{value, {Cookie,Session,_}} ->
		    session_manager(lists:keyreplace(Cookie,1,C,
						     {Cookie,Session,now()}));
		false ->
		    session_manager(C)
	    end;
	{del_session, Cookie} ->
	    C2 = lists:keydelete(Cookie, 1, C),
	    session_manager(C2)
    after
	5000 ->
	    %% garbage collect sessions
	    C2 = lists:zf(fun(Entry={Cookie,Session,Time}) ->
				  Diff = diff(Time,now()),
				  if Diff > ?TTL ->
					  false;
				     true ->
					  {true, Entry}
				  end
			  end, C),
	    session_manager(C2)
    end.

diff({M1,S1,_}, {M2,S2,_}) ->
    (M2-M1)*1000000+(S2-S1).

seed() ->
    case (catch list_to_binary(
	   os:cmd("dd if=/dev/urandom ibs=12 count=1 2>/dev/null"))) of
	<<X:32, Y:32, Z:32>> ->
	    {X, Y, Z};
	_ ->
	    now()
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

retr(Server, User, Password, Nr) ->
    Req = [ret(Nr)],
    [{ok,Msg}] = pop_request(Req, Server, User, Password),
    {Ls,M}=split_head_body(Msg),
    H = parse_headers(Ls),
    {H,M}.

split_head_body(Msg) ->
    split_head_body(Msg,[]).

split_head_body(Msg, Acc) ->
    case get_next_line(Msg) of
	{error, Reason} ->
	    {error, Reason};
	{[], Rest} ->
	    {lists:reverse(Acc), Rest};
	{Line, Rest} ->
	    split_head_body(Rest, [Line|Acc])
    end.

get_next_line(Data) ->
    % io:format("Data = ~p\n", [Data]),
    get_next_line(Data,[]).

get_next_line([D|Ds], Acc) ->
    case split_reply(D,[]) of
	more ->
	    get_next_line(Ds, [D|Acc]);
	{Pre, Rest} when Acc==[] ->
	    {Pre, [Rest|Ds]};
	{Pre, Rest} ->
	    {lists:flatten(lists:reverse([Pre|Acc])), [Rest|Ds]}
    end.

stat(Server, User, Password) ->
    case pop_request([{"STAT",sl}], Server, User, Password) of
	[{ok, Stat}] ->
	    {ok, Stat};
	{error, Reason} ->
	    {error, Reason}
    end.
    

rtop(Server, User, Password, Nr) ->
    Req = [top(Nr)],
    [{ok,Msg}] = pop_request(Req, Server, User, Password),
    {parse_headers(Msg), [M++"\n" || M <- Msg]}.

list(Server, User, Password) ->
    case pop_request([{"LIST",ml}], Server, User, Password) of
	[{ok, Stats}] ->
	    Info = [info(S) || S <- Stats],
	    Req = [top(I#info.nr) || I <- Info],
	    Res = pop_request(Req, Server, User, Password),
	    Hdrs = lists:map(fun({ok,Ls}) -> parse_headers(Ls) end, Res),
	    add_hdrs(Info,Hdrs);
	{error, Reason} ->
	    {error, Reason}
    end.

add_hdrs([], []) -> [];
add_hdrs([I|Is], [H|Hs]) ->
    [I#info{headers=H}|add_hdrs(Is,Hs)].

info(Str) ->
    [NrStr,SizeStr|_] = string:tokens(Str, " \t"),
    #info{nr=to_int(NrStr),size=to_int(SizeStr)}.

top(I) -> {"TOP "++integer_to_list(I)++" 0", ml}.
ret(I) -> {"RETR "++integer_to_list(I), sized}.

del(I) -> {"DELE "++atom_to_list(I), sl}.
    

to_int(Str) ->
    to_int(Str, 0).

to_int([D|Ds], Acc) when D >= $0, D =< $9->
    to_int(Ds, Acc*10+D-$0);
to_int(_, Acc) -> Acc.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

parse_headers(Lines) ->
    parse_headers(Lines, #mhead{}).

parse_headers([], Headers) ->
    Headers;
parse_headers([L1,[$\t|L2]|Lines], Headers) ->
    parse_headers([L1++" "++L2|Lines], Headers);
parse_headers([L1,[$ |L2]|Lines], Headers) ->
    parse_headers([L1++" "++L2|Lines], Headers);
parse_headers([Line|Lines], Headers) ->
    case string:chr(Line, $:) of
	0 ->
	    Headers;
	N ->
	    Key = lowercase(string:strip(string:sub_string(Line, 1, N-1))),
	    Value = string:sub_string(Line, N+2),
	    NewH = add_header(Key, Value, Headers),
	    parse_headers(Lines, NewH)
    end.

parse_header_value(Header) ->
    [Key|Options] = string:tokens(Header, ";"),
    Opts = [string:tokens(O,"=") || O <- Options],
    {Key,Opts}.

lowercase(Str) ->
    [lowercase_ch(S) || S <- Str].

lowercase_ch(C) when C>=$A, C=<$Z -> C + 32;
lowercase_ch(C) -> C.

add_header("content-transfer-encoding", Value, H) ->
    H#mhead{transfer_encoding = Value};
add_header("content-type", Value, H) ->
    H#mhead{content_type = parse_header_value(Value)};
add_header("from", Value, H) ->    H#mhead{from = Value};
add_header("to", Value, H) ->      H#mhead{to = Value};
add_header("cc", Value, H) ->      H#mhead{cc = Value};
add_header("bcc", Value, H) ->     H#mhead{bcc = Value};
add_header("subject", Value, H) -> H#mhead{subject = Value};
add_header("date", Value, H) ->    H#mhead{date = Value};
add_header(Other, Value, H) ->     H#mhead{other = [{Other,Value}|
						      H#mhead.other]}.
    
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

pop_request(Command, Server, User, Password) ->
    proc_lib:spawn_link(?MODULE, ploop,
			[Command, Server, User, Password, self()]),
    receive
	{pop_response, Response} ->
	    Response
    end.

%%
%% first authenticate then run a bunch of commands
%% 

ploop(Command, Server, User, Password, From) ->
    case gen_tcp:connect(Server, 110, [{active, false},
					       {reuseaddr,true},
					       binary]) of
	{ok, Port} ->
	    State = #pstate{port=Port,
			    user=User,
			    pass=Password,
			    cmd=Command,
			    from=From},
	    ploop(init, State);
	_ ->
	    {error, "Failed to contact mail server."}
    end.

%



ploop(init, State) ->
    case receive_reply(State) of
	{ok, Reply, State2} ->
	    % io:format("INIT got +OK ~s\n", [Reply]),
	    psend("USER " ++ State#pstate.user, State#pstate.port),
	    ploop(user, State2);
	{error, Reason, State2} ->
	    % io:format("INIT got -ERR ~s\n", [Reason]),
	    State#pstate.from ! {pop_response, {error, Reason}},
	    gen_tcp:close(State#pstate.port);
	{more, State2} ->
	    % io:format("INIT got more\n", []),
	    ploop(init, State2)
    end;

ploop(user, State) ->
    case receive_reply(State) of
	{ok, Reply, State2} ->
	    % io:format("USER got +OK ~s\n", [Reply]),
	    psend("PASS " ++ State#pstate.pass, State#pstate.port),
	    ploop(pass, State2);
	{error, Reason, State2} ->
	    % io:format("USER got -ERR ~s\n", [Reason]),
	    State#pstate.from ! {pop_response, {error, Reason}},
	    gen_tcp:close(State#pstate.port);
	{more, State2} ->
	    % io:format("USER got more\n", []),
	    ploop(user, State2)
    end;
ploop(pass, State) ->
    case receive_reply(State) of
	{ok, Reply, State2} ->
	    % io:format("PASS got +OK ~s\n", [Reply]),
	    next_cmd(State);
	{error, Reason, State2} ->
	    % io:format("PASS got -ERR ~s\n", [Reason]),
	    State#pstate.from ! {pop_response, {error, Reason}},
	    gen_tcp:close(State#pstate.port);
	{more, State2} ->
	    % io:format("PASS got more\n", []),
	    ploop(pass, State2)
    end;
ploop(sl, State) ->
    case receive_reply(State) of
	{ok, Reply, State2} ->
	    % io:format("SL got +OK ~s\n", [Reply]),
	    next_cmd(State2#pstate{reply=[{ok,Reply}|State2#pstate.reply]});
	{error, Reason, State2} ->
	    % io:format("SL got -ERR ~s\n", [Reason]),
	    next_cmd(State2#pstate{reply=[{error,Reason}|
					  State2#pstate.reply]});
	{more, State2} ->
	    % io:format("SL got more\n", []),
	    ploop(sl, State2)
    end;
ploop(sized, State) ->
    case receive_reply(State) of
	{ok, Reply, State2} ->
	    Size = to_int(Reply),
	    % io:format("MLINE got +OK size=~p\n", [Size]),
	    ploop(sized_cont, State2#pstate{remain=Size,lines=[]});
	{error, Reason, State2} ->
	    % io:format("MLINE got -ERR ~s\n", [Reason]),
	    next_cmd(State2#pstate{reply=[{error,Reason}|
					  State2#pstate.reply]});
	{more, State2} ->
	    % io:format("MLINE got more\n", []),
	    ploop(ml, State2)
    end;
ploop(sized_cont, State) ->
    case receive_data(State) of
	{error, Reason, State2} ->
	    % io:format("SCONT got -ERR ~s\n", [Reason]),
	    next_cmd(State2#pstate{reply=[{error,Reason}|
					  State2#pstate.reply]});
	{more, State2} ->
	    % io:format("SCONT got more\n", []),
	    ploop(sized_cont, State2);
	{done, State2} ->
	    % io:format("SCONT got done\n", []),
	    Data = lists:reverse(State2#pstate.lines),
	    next_cmd(State2#pstate{reply=[{ok, Data}|State2#pstate.reply]})
    end;
ploop(ml, State) ->
    case receive_reply(State) of
	{ok, Reply, State2} ->
	    % io:format("MLINE got +OK ~s\n", [Reply]),
	    ploop(ml_cont, State2#pstate{lines=[]});
	{error, Reason, State2} ->
	    % io:format("MLINE got -ERR ~s\n", [Reason]),
	    next_cmd(State2#pstate{reply=[{error,Reason}|
					  State2#pstate.reply]});
	{more, State2} ->
	    % io:format("MLINE got more\n", []),
	    ploop(ml, State2)
    end;
ploop(ml_cont, State) ->
    case receive_reply(State) of
	{line, Line, State2} ->
	    % io:format("MCONT got +OK ~s\n", [Line]),
	    Lines = State2#pstate.lines,
	    ploop(ml_cont, State2#pstate{lines=[Line|Lines]});
	{error, Reason, State2} ->
	    % io:format("MCONT got -ERR ~s\n", [Reason]),
	    next_cmd(State2#pstate{reply=[{error,Reason}|
					  State2#pstate.reply]});
	{more, State2} ->
	    % io:format("MCONT got more\n", []),
	    ploop(ml_cont, State2);
	{done, State2} ->
	    % io:format("MCONT got done\n", []),
	    Lines = lists:reverse(State2#pstate.lines),
	    next_cmd(State2#pstate{reply=[{ok, Lines}|State2#pstate.reply]})
    end.

%

next_cmd(State=#pstate{cmd=Cmd,reply=Reply}) when Cmd==[]->
    State#pstate.from ! {pop_response, lists:reverse(Reply)},
    gen_tcp:close(State#pstate.port);
next_cmd(State=#pstate{cmd=[Cmd|Cmds]}) ->
    {C,S} = Cmd,
    psend(C, State#pstate.port),
    ploop(S, State#pstate{cmd=Cmds}).

%

psend(Str, Port) ->
    gen_tcp:send(Port, Str++"\r\n").

%

receive_reply(State=#pstate{port=Port,acc=Acc,more=false}) ->
    check_reply(State#pstate.acc, State);
receive_reply(State=#pstate{port=Port,acc=Acc,more=true}) ->
    Res = gen_tcp:recv(Port, 0),
    case Res of
	{ok, Bin} ->
	    % io:format("got ~s~n", [binary_to_list(Bin)]),
	    NAcc = Acc++binary_to_list(Bin),
	    check_reply(NAcc, State);
	Err ->
	    {error, Err, State}
    end.


%

receive_data(State=#pstate{port=Port,acc=Acc,more=false,remain=Remain}) ->
    % io:format("Remain = ~p, more=false, Acc=~p\n", [Remain,length(Acc)]),
    if
	Remain =< length(Acc) ->
	    {Lines, NAcc} = split_at(Acc, Remain),
	    State2 = State#pstate{acc=NAcc,lines=[Lines|State#pstate.lines],
				  remain=0,more=false},
	    {done, State2};
	true ->
	    Rem = Remain - length(Acc),
	    State2 = State#pstate{acc=[],lines=[Acc|State#pstate.lines],
				  remain=Rem, more=true},
	    {more, State2}
    end;
receive_data(State=#pstate{port=Port,acc=Acc,more=true}) when length(Acc)>0 ->
    receive_data(State#pstate{more=false});
receive_data(State=#pstate{port=Port,acc=[],more=true,remain=Remain}) ->
    Res = gen_tcp:recv(Port, 0),
    % io:format("Remain = ~p\n", [Remain]),
    case Res of
	{ok, Bin} ->
	    % io:format("got ~s~n", [binary_to_list(Bin)]),
	    Acc = binary_to_list(Bin),
	    if
		Remain =< length(Acc) ->
		    {Lines, NAcc} = split_at(Acc, Remain),
		    State2 = State#pstate{acc=NAcc,
					  lines=[Lines|State#pstate.lines],
					  remain=0,more=false},
		    {done, State2};
		true ->
		    Rem = Remain - length(Acc),
		    State2 = State#pstate{acc=[],
					  lines=[Acc|State#pstate.lines],
					  remain=Rem, more=true},
		    {more, State2}
	    end;
	Err ->
	    {error, Err, State}
    end.

%

check_reply(Str, State) ->
    case split_reply(Str, []) of
	{"+OK " ++ Res, Rest} ->
	    NewS = State#pstate{acc=Rest,more=false},
	    {ok, Res, NewS};
	{"-ERR " ++ Res, Rest} ->
	    NewS = State#pstate{acc=Rest,more=false},
	    {error, Res, NewS};
	{".", Rest} ->
	    NewS = State#pstate{acc=Rest,more=false},
	    {done, NewS};
	{"."++Line, Rest} ->
	    NewS = State#pstate{acc=Rest,more=false},
	    {line, Line, NewS};
	{Line, Rest} ->
	    NewS = State#pstate{acc=Rest,more=false},
	    {line, Line, NewS};
	more ->
	    {more, State#pstate{acc=Str, more=true}}
    end.

%

split_reply("\r\n"++Rest, Pre) ->
    {lists:reverse(Pre), Rest};
split_reply([H|T], Pre) ->
    split_reply(T, [H|Pre]);
split_reply("", Pre) ->
    more.
	    
%

split_at(L,N) ->
    split_at(L,N,[]).

split_at(L,0,Acc) ->
    {lists:reverse(Acc),L};
split_at([C|Cs], N, Acc) ->    
    split_at(Cs, N-1, [C|Acc]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_val(Key, L, Default) ->
    case lists:keysearch(Key, 1, L) of
	{value, {_, undefined}} -> Default;
	{value, {_, Val}} -> Val;
	_ -> Default
    end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

smtp_send(Server, Session, Recipients, Message) ->
    case catch smtp_send2(Server, Session, Recipients, Message) of
	ok ->
	    ok;
	{error, Reason} ->
	    {error, Reason};
	_ ->
	    {error, "Failed to send message."}
    end.

smtp_send2(Server, Session, Recipients, Message) ->
    {ok, Port} = gen_tcp:connect(Server, 25, [{active, false},
					      {reuseaddr,true},
					      binary]),
    smtp_expect(220, Port, "SMTP server does not respond"),
    smtp_put("MAIL FROM: " ++ Session#session.user++"@"++?MAILDOMAIN, Port),
    smtp_expect(250, Port, "Sender not accepted by mail server"),
    send_recipients(Recipients,Port),
    smtp_put("DATA", Port),
    smtp_expect(354, Port, "Message not accepted by mail server."),
    smtp_put(Message, Port),
    smtp_put(".", Port),
    smtp_expect(250, Port, "Message not accepted by mail server."),
    smtp_put("QUIT", Port),
    ok.

send_recipients([], Port) ->
    ok;
send_recipients([R|Rs], Port) ->
    smtp_put("RCPT TO: " ++ R, Port),
    smtp_expect(250, Port, io_lib:format("Recipient ~s not accepted.",[R])),
    send_recipients(Rs, Port).

smtp_put(Message, Port) ->
    gen_tcp:send(Port, [Message,"\r\n"]).

smtp_expect(Code, Port, ErrorMsg) ->
    smtp_expect(Code, Port, [], ErrorMsg).

smtp_expect(Code, Port, Acc, ErrorMsg) ->
    Res = gen_tcp:recv(Port, 0, ?SENDTIMEOUT),
    case Res of
	{ok, Bin} ->
	    % io:format("got ~s~n", [binary_to_list(Bin)]),
	    NAcc = Acc++binary_to_list(Bin),
	    case string:chr(NAcc, $\n) of
		0 ->
		    smtp_expect(Code, Port, NAcc, ErrorMsg);
		N ->
		    ResponseCode = to_int(NAcc),
		    if 
			ResponseCode == Code -> ok;
			true -> throw({error, ErrorMsg})
		    end
	    end;
	Err ->
	    throw({error, Err})
    end.
    
    
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

base64_2_str(Str) ->
    b642str(Str, 0, 0, []).

b642str([$=|_], Acc, N, Out) ->
    case N of
	2 ->
	    %% If I have seen two characters before the =
	    %% Them I'm encoding one byte
	    lists:reverse([(Acc bsr 4)|Out]);
	3 ->
	    %% If I have seen three characters before the =
	    %% Them I'm encoding two bytes
	    B1 = Acc bsr 10,
	    B2 = (Acc bsr 2) band 16#ff,
	    lists:reverse([B2,B1|Out]);
	_ ->
	    exit({bad,b64,N})
    end;
b642str([H|T], Acc, N, Out) ->
    case d(H) of
	no ->
	    b642str(T, Acc, N, Out);
	I  -> 
	    Acc1 = (Acc bsl 6) bor I,
	    case N of 
		3 ->
		    B1 = Acc1 bsr 16,
		    B2 = (Acc1 band 16#ffff) bsr 8,
		    B3 = (Acc1 band 16#ff),
		    b642str(T, 0, 0, [B3,B2,B1|Out]);
		_ ->
		    b642str(T, Acc1, N+1, Out)
	    end
    end;
b642str([], 0, 0, Out) ->
    lists:reverse(Out).

d(X) when X >= $A, X =<$Z ->  X - $A;
d(X) when X >= $a, X =<$z ->  X - $a + 26;
d(X) when X >= $0, X =<$9 ->  X - $0 + 52;
d($+)                     -> 62;
d($/)                     -> 63;
d(_)                      -> no.