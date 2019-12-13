using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Action.StaffAccount
{
    public abstract class AccountAction : INotifyPropertyChanged
    {
        private string header;
        public string Header => header;

        private string description;
        public string Description => description;

        private bool canBeApplied;
        public bool CanBeApplied => canBeApplied;

        private bool canBeAppliedToAll = false;
        public bool CanBeAppliedToAll => canBeAppliedToAll;

        public bool CanShowDetails { get; protected set; } = false;

        public Prop<bool> ApplyToAll { get; set; } = new Prop<bool>() { Value = false };
        
        bool indicator = false;
        public bool Indicator
        {
            get => indicator;
            set
            {
                indicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Indicator)));
            }
        }

        public virtual FlowDocument GetDetails(State.Linked.LinkedStaffMember account) { return null; }

        public abstract Task Apply(State.Linked.LinkedStaffMember linkedAccount);

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        public AccountAction(string header, string description, bool canBeApplied, bool canBeAppliedToAll = false)
        {
            this.header = header;
            this.description = description;
            this.canBeApplied = canBeApplied;
            this.canBeAppliedToAll = canBeAppliedToAll;
        }
    }
}
