//-*-Mode:java;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
// ex: set ft=java fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
//
// MIT License
//
// Copyright (c) 2011-2017 Michael Truog <mjtruog at gmail dot com>
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//

package org.cloudi.tests.http;

import com.ericsson.otp.erlang.OtpErlangPid;
import org.cloudi.API;

public class Task implements Runnable
{
    private API api;
     
    public Task(final int thread_index)
    {
        try
        {
            this.api = new API(thread_index);
        }
        catch (API.InvalidInputException e)
        {
            e.printStackTrace(API.err);
            System.exit(1);
        }
        catch (API.MessageDecodingException e)
        {
            e.printStackTrace(API.err);
            System.exit(1);
        }
        catch (API.TerminateException e)
        {
            API.err.println("terminate http java (before init)");
            System.exit(1);
        }
    }

    public void text(Integer request_type, String name, String pattern,
                     byte[] request_info, byte[] request,
                     Integer timeout, Byte priority,
                     byte[] trans_id, OtpErlangPid pid)
                     throws API.ReturnAsyncException,
                            API.ReturnSyncException,
                            API.InvalidInputException
    {
        final String value = new String(request);
        API.out.println("(" + value + ")");
        assert "Test Text" == value : value;
        this.api.return_(request_type, name, pattern,
                         ("").getBytes(), ("Test Response").getBytes(),
                         timeout, trans_id, pid);
    }
 
    public void run()
    {
        try
        {
            this.api.subscribe("text/post", this, "text");
            Object result = this.api.poll();
            assert result == Boolean.FALSE;
        }
        catch (API.TerminateException e)
        {
        }
        catch (Exception e)
        {
            e.printStackTrace(API.err);
        }
        API.out.println("terminate http java");
    }
}
