using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using static AbstractAccountApi.ObservableProperties;

namespace AccountApi
{
    public interface IRule
    {
        Rule Rule { get; }
        RuleType RuleType { get; }
        RuleAction RuleAction { get; }

        string Header { get; }
        string Description { get; }
        Prop<string> ShortInfo { get; }

        bool Enabled { get; set; }

        JObject ToJson();
        void SetConfig(int ID, string data);
        string GetConfig(int ID);

        bool ShouldApply(object obj);
        void Modify(object obj);
    }
}
