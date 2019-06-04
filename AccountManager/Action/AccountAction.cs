using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Action
{
    public abstract class AccountAction
    {
        private string header;
        public string Header => header;

        private string description;
        public string Description => description;

        private bool canBeApplied;
        public bool CanBeApplied => canBeApplied;

        public Prop<bool> InProgress { get; set; } = new Prop<bool>() { Value = false };

        public abstract Task Apply(LinkedAccount linkedAccount);

        public AccountAction(string header, string description, bool canBeApplied)
        {
            this.header = header;
            this.description = description;
            this.canBeApplied = canBeApplied;
        }
    }
}
