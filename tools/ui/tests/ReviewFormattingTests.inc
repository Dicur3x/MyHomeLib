procedure TestReviewFormatting;
var Parser: TReviewParser; Reviews, Annotation: TStringList; Details: TfrmBookDetails;
  Expected, Saved, HTML: string; I, HeaderCount: Integer;
begin
  Parser:=TReviewParser.Create; Reviews:=TStringList.Create; Annotation:=TStringList.Create;
  try
    HTML:='<h2 class="heading">Аннотация</h2><p class="intro">Первая &amp; вторая.</p>'+
      '<p>Новый абзац.</p><form></form>'+
      '<a href="/polka/show/1">Первый</a> в 01.01.2026<br>Первая строка.<br />Вторая строка.'+
      '<br><br>Следующий абзац.<div></div>'+
      '<a class="user" HREF=''/polka/show/2''><strong>Второй &amp; друг</strong></a> в 02.01.2026<BR />'+
      '<p class="body">Самостоятельный отзыв.</p><p>Его продолжение.</p><div> </div>'+
      '<div id="newann"><a href="/polka/show/999">Не отзыв</a><br>Форма ответа.</div>';
    Parser.ParsePage(HTML,'https://flibusta.is/b/1/',Reviews,Annotation);
    Expected:='Первый:'+sLineBreak+'Первая строка.'+sLineBreak+'Вторая строка.'+sLineBreak+sLineBreak+
      'Следующий абзац.'+sLineBreak+sLineBreak+'Второй & друг:'+sLineBreak+
      'Самостоятельный отзыв.'+sLineBreak+sLineBreak+'Его продолжение.';
    Require(Reviews.Text.Trim=Expected,'Reviews lost author boundaries, BR or paragraphs: '+Reviews.Text);
    Require(Annotation.Text.Trim='Первая & вторая.'+sLineBreak+sLineBreak+'Новый абзац.',
      'Annotation paragraphs or entities changed: '+Annotation.Text);
    Writeln('PASS review formatting separates reviewers paragraphs and HTML break variants without Markdown artifacts');

    Parser.ParsePage('<h2>Отзывы</h2><a href="/polka/show/1">Первый</a>'+
      '<p>Начало<br>Продолжение</p><a href="/polka/show/2">Второй</a><br>'+
      '<p>Второй отзыв.</p><div id="newann"></div>','https://flibusta.is/b/1/',Reviews,Annotation);
    Require(Reviews.Text.Trim='Первый:'+sLineBreak+'Начало'+sLineBreak+'Продолжение'+sLineBreak+sLineBreak+
      'Второй:'+sLineBreak+'Второй отзыв.','First paragraph was mistaken for author/date header or reviewers bled together');
    Parser.ParsePage('<h2>Аннотация</h2><p>Описание.</p><h3>Отзывы</h3>'+
      '<a href="/polka/show/4">Читатель</a> дата<br><p>Текст.</p><blockquote>Цитата.</blockquote>'+
      '<ul><li>Один</li><li>Два</li></ul><hr /><a href="/stat/r/1">Статистика</a>'+
      '<a href="/polka/show/5">Не отзыв</a><br>Навигация.','https://lib.rus.ec/b/1/',Reviews,Annotation);
    Require((Pos('Читатель:'+sLineBreak+'Текст.'+sLineBreak+sLineBreak+'Цитата.',Reviews.Text)=1) and
      (Pos('• Один'+sLineBreak+'• Два',Reviews.Text)>0) and (Pos('Не отзыв',Reviews.Text)=0) and
      (Annotation.Text.Trim='Описание.'),'Librusec block boundaries, quotation or list changed');
    Writeln('PASS review formatting handles missing div separators headerless paragraphs and Librusec review boundaries');

    HTML:='<h2>Отзывы</h2>';
    for I:=1 to 120 do HTML:=HTML+'<a href="/polka/show/'+IntToStr(I)+'">Читатель '+IntToStr(I)+
      '</a><br><p>Первый абзац.</p><p>Второй абзац.</p><div></div>';
    HTML:=HTML+'<a name="newann"></a>';
    Parser.ParsePage(HTML,'https://flibusta.is/b/1/',Reviews,Annotation);
    HeaderCount:=0;
    for var ReviewLine in Reviews.Text.Split([#13,#10]) do
      if ReviewLine.StartsWith('Читатель ') and ReviewLine.EndsWith(':') then Inc(HeaderCount);
    Require((HeaderCount=120) and
      (Pos('Читатель 120:'+sLineBreak+'Первый абзац.'+sLineBreak+sLineBreak+'Второй абзац.',Reviews.Text)>0),
      'Long review list lost reviewers or their paragraph structure');
    Writeln('PASS long review lists preserve all reviewer and paragraph boundaries');
    Details:=TfrmBookDetails.Create(nil);
    try
      Details.Review:=Reviews.Text; Details.pcBookInfo.ActivePage:=Details.tsReview; Details.Show;
      Application.ProcessMessages;
      Require(Details.mmReview.WordWrap and (Details.mmReview.ScrollBars=ssVertical) and
        (Details.Review.Trim=Reviews.Text.Trim) and not Details.ReviewChanged and
        (SendMessage(Details.mmReview.Handle,EM_GETLINECOUNT,0,0)>120),
        'Book review memo lost paragraph lines, wrapping, scrolling or marked saved text edited');
      Saved:='Сохранённый старый отзыв: один цельный абзац. Второй автор: его текст.';
      Details.Review:=Saved;
      Require((Details.Review.Trim=Saved) and not Details.ReviewChanged,'Opening cached reviews altered existing saved text');
      Details.mmReview.Lines.Add('Моя заметка.');
      Require(Details.ReviewChanged,'Actual review edit was not marked changed');
      if ParamStr(2)='visual' then begin Details.Hide; Details.ShowModal; end;
    finally Details.Free; end;
    Writeln('PASS native review memo wraps scrolls preserves cached text and tracks real edits');
    Parser.ParsePage('<h2>Аннотация</h2><p>Без отзывов.</p><div id="newann"></div>',
      'https://flibusta.is/b/1/',Reviews,Annotation);
    Require((Reviews.Count=0) and (Annotation.Text.Trim='Без отзывов.'),'Empty reviews became fabricated content');
    Writeln('PASS book page without reviews remains empty');
  finally Annotation.Free; Reviews.Free; Parser.Free; end;
end;
