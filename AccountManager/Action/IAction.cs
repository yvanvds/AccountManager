using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Action
{
    public interface IAction
    {
        string Header { get; }
        string Description { get; }
        bool CanBeApplied { get; }
        Prop<bool> InProgress { get; set; }
        Task Apply(LinkedGroup linkedGroup);
    }
}
