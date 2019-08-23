using System.Threading.Tasks;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Action
{
    public enum AccountActionType
    {
        AddToDirectoryAndSmartschool,
        AddToSmartschool,
        ModifyDirectoryData,
        MoveDirectoryClassGroup,
        MoveSmartschoolClassGroup,
        RemoveFromDirectory,
        RemoveFromGoogle,
        RemoveFromDirectoryAndSmartschool,
        NoAction,
    }

    public abstract class AccountAction
    {
        AccountActionType accountActionType;
        public AccountActionType AccountActionType => accountActionType;

        private string header;
        public string Header => header;

        private string description;
        public string Description => description;

        private bool canBeApplied;
        public bool CanBeApplied => canBeApplied;

        private bool canBeAppliedToAll = false;
        public bool CanBeAppliedToAll => canBeAppliedToAll;

        public Prop<bool> ApplyToAll { get; set; } = new Prop<bool>() { Value = false };

        public Prop<bool> InProgress { get; set; } = new Prop<bool>() { Value = false };

        public abstract Task Apply(LinkedAccount linkedAccount);

        public AccountAction(AccountActionType accountActionType, string header, string description, bool canBeApplied, bool canBeAppliedToAll = false)
        {
            this.accountActionType = accountActionType;
            this.header = header;
            this.description = description;
            this.canBeApplied = canBeApplied;
            this.canBeAppliedToAll = canBeAppliedToAll;
        }
    }
}
